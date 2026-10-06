#!/usr/bin/perl
#
# TicMambo - matches incoming TIC files (FTS-5006) with the files they
# describe and moves the good pairs to a separate directory for the file
# echo processor.
#
# Usage: ticmambo.pl [config]
#
# Without arguments ticmambo.cfg next to the script is used.
#
# Free software under the WTFPL, version 2. See COPYING.

use strict;
use warnings;
use feature qw(fc);

use Encode qw(decode encode find_encoding);
use Encode::Locale;
use File::Spec;
use File::Copy qw(move);
use FindBin;
use Compress::Zlib qw(crc32);
use POSIX qw(strftime);

my $IS_WIN = $^O eq 'MSWin32';
require Win32::File if $IS_WIN;

# Perl's stat has no birth time; on Linux it is available via statx(2).
my $SYS_statx = $^O eq 'linux' && eval { require 'syscall.ph'; SYS_statx() };

my %LEVELS = (error => 0, warn => 1, info => 2, debug => 3);

# Keyword => [type, default]. Types: dir, path, bool, days, int, charset,
# level, action.
my %OPTIONS = (
    TicPath              => ['dir',     undef],
    FilesPath            => ['dir',     undef],
    DestPath             => ['dir',     undef],
    TicCharset           => ['charset', 'cp866'],
    ForceCaseInsensitive => ['bool',    0],
    UseCreationTime      => ['bool',    1],
    WaitForFileDays      => ['days',    3],
    DeleteOrphanTics     => ['bool',    0],
    WaitForHiddenTicDays => ['days',    7],
    TouchFiles           => ['bool',    0],
    OverwriteExisting    => ['bool',    0],
    MaxTicSize           => ['int',     65536],
    CorruptTicAction      => ['action',  'move'],
    CorruptTicPath        => ['dir',     undef],
    LogFile              => ['path',    undef],
    LogLevel             => ['level',   'info'],
);

my %cfg;
my $log_fh;

binmode STDERR, ':encoding(console_out)';

my $cfg_file = @ARGV ? $ARGV[0] : File::Spec->catfile($FindBin::Bin, 'ticmambo.cfg');
eval { load_config($cfg_file); 1 } or do {
    print STDERR "ticmambo: $@";
    exit 1;
};

if (defined $cfg{LogFile}) {
    open $log_fh, '>>:encoding(UTF-8)', $cfg{LogFile} or do {
        print STDERR "ticmambo: cannot open log file " . disp($cfg{LogFile}) . ": $!\n";
        exit 1;
    };
    select((select($log_fh), $| = 1)[0]);
}
else {
    $log_fh = \*STDERR;
}

logmsg('debug', 'started, config ' . disp($cfg_file));

opendir(my $dh, $cfg{TicPath}) or do {
    logmsg('error', 'cannot read TicPath ' . disp($cfg{TicPath}) . ": $!");
    exit 1;
};
my @tics = sort grep { /\.tic\z/i } readdir $dh;
closedir $dh;

process_tic($_) for @tics;

logmsg('debug', 'finished');
exit 0;


sub load_config {
    my ($file) = @_;

    open my $fh, '<:raw', $file or die "cannot open config " . disp($file) . ": $!\n";
    my $data = do { local $/; <$fh> } // '';
    close $fh;
    $data =~ s/^\xEF\xBB\xBF//;

    my (%seen, $n);
    for my $line (split /\r\n|\r|\n/, $data) {
        $n++;
        next if $line =~ /^\s*(?:[;#]|\z)/;

        my ($key, $value) = $line =~ /^\s*(\S+)\s*(.*?)\s*\z/;
        my ($name) = grep { lc $_ eq lc $key } keys %OPTIONS;
        die "$file line $n: unknown keyword '$key'\n" unless defined $name;
        die "$file line $n: no value for '$name'\n" unless length $value;
        die "$file line $n: '$name' is set twice\n" if $seen{$name}++;

        $cfg{$name} = parse_value($name, $value)
            // die "$file line $n: invalid value '$value' for '$name'\n";
    }

    for my $name (keys %OPTIONS) {
        $cfg{$name} = $OPTIONS{$name}[1] unless exists $cfg{$name};
    }
    $cfg{FilesPath} = $cfg{TicPath} unless defined $cfg{FilesPath};

    for my $name (qw(TicPath DestPath)) {
        die "'$name' is not set\n" unless defined $cfg{$name};
    }
    die "'CorruptTicPath' must be set when CorruptTicAction is Move\n"
        if $cfg{CorruptTicAction} eq 'move' && !defined $cfg{CorruptTicPath};

    for my $name (grep { $OPTIONS{$_}[0] eq 'dir' && defined $cfg{$_} } keys %OPTIONS) {
        die "$name " . disp($cfg{$name}) . " is not a directory\n" unless -d $cfg{$name};
    }
}

sub parse_value {
    my ($name, $value) = @_;
    my $type = $OPTIONS{$name}[0];

    return $value if $type eq 'dir' || $type eq 'path';
    if ($type eq 'bool') {
        return 1 if $value =~ /^yes\z/i;
        return 0 if $value =~ /^no\z/i;
        return undef;
    }
    return $value =~ /^\d+\z/ ? $value + 0 : undef if $type eq 'days' || $type eq 'int';
    return find_encoding($value) ? $value : undef if $type eq 'charset';
    return exists $LEVELS{lc $value} ? lc $value : undef if $type eq 'level';
    return $value =~ /^(?:move|delete|keep)\z/i ? lc $value : undef if $type eq 'action';
    die "internal error: unknown option type $type\n";
}

sub logmsg {
    my ($level, $msg) = @_;
    return if $LEVELS{$level} > $LEVELS{$cfg{LogLevel}};
    printf $log_fh "%s [%-5s] %s\n", strftime('%Y-%m-%d %H:%M:%S', localtime), uc $level, $msg;
}

# File system name (bytes) to text, for messages.
sub disp {
    my ($bytes) = @_;
    return decode(locale_fs => $bytes);
}

sub is_regular {
    my ($path) = @_;
    return lstat($path) && -f _ && !-l _;
}

sub age_days {
    my ($path) = @_;
    my @st = stat $path or return 0;
    my $time;
    if ($cfg{UseCreationTime}) {
        # On Win32 Perl reports the creation time as ctime.
        $time = $IS_WIN ? $st[10] : birth_time($path);
    }
    $time = $st[9] unless defined $time;
    return (time - $time) / 86400;
}

# Returns the birth time from statx(2), or undef if it is not available.
sub birth_time {
    my ($path) = @_;
    return undef unless $SYS_statx;

    use constant { AT_FDCWD => -100, STATX_BTIME => 0x800, STX_BTIME_OFFSET => 80 };
    my $buf = "\0" x 256;    # sizeof(struct statx)
    return undef if syscall($SYS_statx, AT_FDCWD, $path, 0, STATX_BTIME, $buf) != 0;
    return undef unless unpack('L', $buf) & STATX_BTIME;

    # stx_btime.tv_sec is s64; unpacked in halves to work with 32-bit perls.
    my ($lo, $hi) = unpack 'Ll', substr($buf, STX_BTIME_OFFSET, 8);
    return $hi * 2**32 + $lo;
}

sub is_hidden {
    my ($path) = @_;
    return 0 unless $IS_WIN;
    my $attr;
    return Win32::File::GetAttributes($path, $attr) && ($attr & Win32::File::HIDDEN());
}

sub unhide {
    my ($path) = @_;
    return unless is_hidden($path);
    my $attr;
    Win32::File::GetAttributes($path, $attr)
        && Win32::File::SetAttributes($path, $attr & ~Win32::File::HIDDEN())
        or logmsg('warn', 'cannot clear hidden attribute of ' . disp($path));
}

sub process_tic {
    my ($tic) = @_;
    my $tic_path = File::Spec->catfile($cfg{TicPath}, $tic);
    my $tic_disp = disp($tic);

    return unless is_regular($tic_path);

    if (is_hidden($tic_path) && age_days($tic_path) < $cfg{WaitForHiddenTicDays}) {
        logmsg('debug', "$tic_disp is hidden, skipping");
        return;
    }

    my $size = -s _;
    if ($size > $cfg{MaxTicSize}) {
        return corrupt_tic($tic, "size $size exceeds MaxTicSize");
    }

    my $data = '';
    open my $fh, '<:raw', $tic_path or do {
        logmsg('error', "cannot open $tic_disp: $!");
        return;
    };
    my $read = read $fh, $data, $cfg{MaxTicSize} + 1;
    close $fh;
    unless (defined $read) {
        logmsg('error', "cannot read $tic_disp: $!");
        return;
    }
    return corrupt_tic($tic, 'size exceeds MaxTicSize') if length $data > $cfg{MaxTicSize};
    return corrupt_tic($tic, 'contains NUL bytes') if $data =~ /\0/;

    # Keywords are case insensitive; the first occurrence wins.
    my %kw;
    for my $line (split /\r\n|\r|\n/, $data) {
        my ($key, $value) = $line =~ /^[ \t]*(\S+)[ \t]*(.*?)[ \t]*\z/ or next;
        $key = lc $key;
        $kw{$key} = $value unless exists $kw{$key};
    }

    my @names;
    for my $raw (grep { defined && length } $kw{lfile}, $kw{fullname}, $kw{file}) {
        my $name = decode($cfg{TicCharset}, $raw);
        if (my $why = invalid_name($name)) {
            return corrupt_tic($tic, "file name '$name' $why");
        }
        push @names, $name;
    }
    return corrupt_tic($tic, 'no File or Lfile') unless @names;
    return corrupt_tic($tic, "invalid Size '$kw{size}'")
        if defined $kw{size} && $kw{size} !~ /^\d+\z/;

    my (@why, %seen);
    for my $f (map { find_files($_) } @names) {
        my ($file, $dest_name) = @$f;
        next if $seen{$file}++;
        my $file_path = File::Spec->catfile($cfg{FilesPath}, $file);
        my $file_disp = disp($file);
        if (defined(my $why = mismatch(\%kw, $file_path))) {
            push @why, "$file_disp does not match: $why";
            next;
        }
        logmsg('info', "$tic_disp: $file_disp is good, moving"
            . ($dest_name eq $file ? '' : ' as ' . disp($dest_name)));
        if (move_files($cfg{DestPath}, [$file_path, $dest_name], [$tic_path, $tic]) && $cfg{TouchFiles}) {
            utime undef, undef, File::Spec->catfile($cfg{DestPath}, $dest_name)
                or logmsg('warn', "cannot touch " . disp($dest_name) . ": $!");
        }
        return;
    }
    my $why = @why ? join('; ', @why) : 'no file ' . join(' / ', @names);

    if (age_days($tic_path) < $cfg{WaitForFileDays}) {
        logmsg('info', "$tic_disp: $why, waiting");
    }
    elsif ($cfg{DeleteOrphanTics}) {
        logmsg('info', "$tic_disp: $why, deleting tic");
        delete_files($tic_path);
    }
    else {
        logmsg('info', "$tic_disp: $why, moving tic");
        move_files($cfg{DestPath}, [$tic_path, $tic]);
    }
}

# Returns the reason why a file name from a tic must not be used, or undef.
sub invalid_name {
    my ($name) = @_;
    return 'contains a path separator or drive letter' if $name =~ m{[/\\:]};
    return 'contains control characters' if $name =~ /[\x00-\x1f\x7f]/;
    return 'refers to a directory' if $name eq '.' || $name eq '..';
    return 'is a reserved device name'
        if $name =~ /^(?:CON|PRN|AUX|NUL|COM\d|LPT\d|CONIN\$|CONOUT\$)(?:\.|\z)/i;
    return undef;
}

# Looks for the file in FilesPath. Returns [name on disk, name for DestPath]
# pairs: the file itself first, then its copies renamed by the mailer.
sub find_files {
    my ($name) = @_;

    my $fs_name = eval { encode(locale_fs => $name, Encode::FB_CROAK | Encode::LEAVE_SRC) };
    unless (defined $fs_name) {
        logmsg('warn', "'$name' cannot be represented in the file system encoding");
        return;
    }

    opendir(my $dh, $cfg{FilesPath}) or do {
        logmsg('error', 'cannot read FilesPath ' . disp($cfg{FilesPath}) . ": $!");
        return;
    };
    my @entries = sort readdir $dh;
    closedir $dh;

    my $ci = $cfg{ForceCaseInsensitive};
    my $want = $ci ? fc $name : $name;
    my (@files, @copies);
    for my $e (@entries) {
        my $have = $ci ? fc disp($e) : disp($e);
        if ($e eq $fs_name) {
            unshift @files, [$e, $e];
        }
        elsif ($ci && $have eq $want) {
            push @files, [$e, $e];
        }
        elsif (is_renamed_copy($have, $want)) {
            push @copies, [$e, $fs_name];
        }
    }
    return grep { is_regular(File::Spec->catfile($cfg{FilesPath}, $_->[0])) } @files, @copies;
}

# Mailers rename a received file when one with the same name already exists:
# file.zip -> file.zip.1 (binkd "postfix" style) or file.zi0, file.z0a
# (binkd "extension" style).
sub is_renamed_copy {
    my ($cand, $name) = @_;

    return 1 if length $cand > length($name) + 1 && substr($cand, 0, length($name) + 1) eq "$name.";

    my $dot = rindex $name, '.';
    return 0 if $dot < 0 || length $cand != length $name;
    my $i = $dot + 1;
    return 0 unless substr($cand, 0, $i) eq substr($name, 0, $i);
    $i++ while $i < length $name && substr($cand, $i, 1) eq substr($name, $i, 1);
    return $i < length $name && substr($cand, $i) =~ /^[0-9a-z]+\z/i;
}

# Returns the reason why the file does not match the tic, or undef.
sub mismatch {
    my ($kw, $path) = @_;

    my $crc = $kw->{crc};
    return 'no Crc in tic' unless defined $crc && length $crc;
    return "invalid Crc '$crc'" unless $crc =~ /^[0-9A-Fa-f]{8}\z/;

    my $size = -s $path;
    if (defined $kw->{size}) {
        return "size is $size, tic says $kw->{size}" if $kw->{size} != $size;
    }

    open my $fh, '<:raw', $path or return "cannot open: $!";
    my ($buf, $sum, $n) = ('', 0);
    $sum = crc32($buf, $sum) while $n = read $fh, $buf, 65536;
    close $fh;
    return "read error: $!" unless defined $n;

    $sum = sprintf '%08X', $sum;
    return "CRC is $sum, tic says " . uc $crc if $sum ne uc $crc;
    return undef;
}

# Moves [path, name] pairs to $dir. Nothing is moved if a file with the same
# name is already there, unless OverwriteExisting is set.
sub move_files {
    my ($dir, @files) = @_;

    unless ($cfg{OverwriteExisting}) {
        for my $f (@files) {
            if (-e File::Spec->catfile($dir, $f->[1])) {
                logmsg('warn', disp($f->[1]) . ' already exists in ' . disp($dir) . ', skipping');
                return 0;
            }
        }
    }
    for my $f (@files) {
        my ($src, $name) = @$f;
        my $dst = File::Spec->catfile($dir, $name);
        unless (move($src, $dst)) {
            logmsg('error', 'cannot move ' . disp($src) . ' to ' . disp($dst) . ": $!");
            return 0;
        }
        logmsg('debug', 'moved ' . disp($src) . ' to ' . disp($dst));
        # The file echo processor must not overlook anything in DestPath.
        unhide($dst) if $dir eq $cfg{DestPath};
    }
    return 1;
}

sub delete_files {
    for my $path (@_) {
        if (unlink $path) {
            logmsg('debug', 'deleted ' . disp($path));
        }
        else {
            logmsg('error', 'cannot delete ' . disp($path) . ": $!");
        }
    }
}

sub corrupt_tic {
    my ($tic, $why) = @_;
    my $tic_path = File::Spec->catfile($cfg{TicPath}, $tic);
    my $action = $cfg{CorruptTicAction};

    logmsg('warn', disp($tic) . ": corrupt tic ($why), action: $action");
    if ($action eq 'delete') {
        delete_files($tic_path);
    }
    elsif ($action eq 'move') {
        move_files($cfg{CorruptTicPath}, [$tic_path, $tic]);
    }
    return;
}
