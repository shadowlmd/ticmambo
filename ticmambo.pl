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

use 5.016;
use warnings;

use Cwd qw(abs_path);
use Encode qw(decode encode find_encoding);
use Encode::Locale;
use File::Spec;
use File::Copy qw(move);
use FindBin;
use Compress::Zlib qw(crc32);
use POSIX qw(strftime);

my $IS_WIN = $^O eq 'MSWin32';
if ($IS_WIN) {
    require Win32;
    require Win32::File;
}

# Perl's stat has no birth time; on Linux it is available via statx(2).
my $SYS_statx = $^O eq 'linux' && eval { require 'syscall.ph'; SYS_statx() };
use constant { AT_FDCWD => -100, STATX_BTIME => 0x800, STX_BTIME_OFFSET => 80 };
use constant LITTLE_ENDIAN => pack('L', 1) eq pack('V', 1);

my %LEVELS = (error => 0, warn => 1, info => 2, debug => 3);

# Keyword => [type, default]. Types: dir, path, bool, days, int, charset,
# level, action.
my %OPTIONS = (
    TicPath                => ['dir',     undef],
    FilesPath              => ['dir',     undef],
    DestPath               => ['dir',     undef],
    TicCharset             => ['charset', find_encoding('cp866')],
    IgnoreCase             => ['bool',    $IS_WIN ? 1 : 0],
    UseCreationTime        => ['bool',    1],
    WaitForFileDays        => ['days',    3],
    DeleteOrphanTics       => ['bool',    0],
    WaitForHiddenTicDays   => ['days',    7],
    TouchFiles             => ['bool',    0],
    FixShortName           => ['bool',    0],
    AddFullname            => ['bool',    0],
    OverwriteExisting      => ['bool',    0],
    MaxTicSize             => ['int',     65536],
    CorruptTicAction       => ['action',  'move'],
    CorruptTicPath         => ['dir',     undef],
    LogFile                => ['path',    undef],
    LogLevel               => ['level',   'info'],
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
    $log_fh->autoflush(1);
}
else {
    $log_fh = \*STDERR;
}

logmsg('debug', 'started, config ' . disp($cfg_file));

opendir(my $dh, $cfg{TicPath}) or do {
    logmsg('error', 'cannot read TicPath ' . disp($cfg{TicPath}) . ": $!");
    exit 1;
};
my @tics;
while (defined(my $e = readdir $dh)) {
    push @tics, $e if $e =~ /\.tic\z/i;
}
closedir $dh;

process_tic($_) for sort @tics;

logmsg('debug', 'finished');
exit 0;


sub load_config {
    my ($file) = @_;
    my $file_disp = disp($file);

    open my $fh, '<:raw', $file or die "cannot open config $file_disp: $!\n";
    my $data = do { local $/; <$fh> } // '';
    close $fh;
    # UTF-8, or the system encoding if the config is not valid UTF-8.
    my $text = eval { decode('UTF-8', $data, Encode::FB_CROAK | Encode::LEAVE_SRC) }
        // decode(locale => $data);
    $text =~ s/^\x{FEFF}//;

    my (%seen, $n);
    for my $line (split /\r\n|\r|\n/, $text) {
        $n++;
        next if $line =~ /^\s*(?:[;#]|\z)/;

        my ($key, $value) = $line =~ /^\s*(\S+)\s*(.*?)\s*\z/;
        my ($name) = grep { lc $_ eq lc $key } keys %OPTIONS;
        die "$file_disp line $n: unknown keyword '$key'\n" unless defined $name;
        die "$file_disp line $n: no value for '$name'\n" unless length $value;
        die "$file_disp line $n: '$name' is set twice\n" if $seen{$name}++;

        $cfg{$name} = parse_value($name, $value)
            // die "$file_disp line $n: invalid value '$value' for '$name'\n";
    }

    for my $name (keys %OPTIONS) {
        $cfg{$name} = $OPTIONS{$name}[1] unless exists $cfg{$name};
    }
    $cfg{FilesPath} = $cfg{TicPath} unless defined $cfg{FilesPath};

    for my $name (qw(TicPath DestPath)) {
        die "'$name' is not set\n" unless defined $cfg{$name};
    }
    die "'CorruptTicPath' must be set when 'CorruptTicAction' is Move\n"
        if $cfg{CorruptTicAction} eq 'move' && !defined $cfg{CorruptTicPath};

    my %real;
    for my $name (grep { $OPTIONS{$_}[0] eq 'dir' && defined $cfg{$_} } keys %OPTIONS) {
        die "'$name' " . disp($cfg{$name}) . " is not a directory\n" unless -d $cfg{$name};
        $real{$name} = disp(abs_path($cfg{$name}) // $cfg{$name});
        $real{$name} = fc $real{$name} if $IS_WIN;
    }
    # Files must not be moved to the directory they are taken from.
    for my $to (grep { defined $real{$_} } qw(DestPath CorruptTicPath)) {
        for my $from (qw(TicPath FilesPath)) {
            die "'$to' must not be the same directory as '$from'\n" if $real{$to} eq $real{$from};
        }
    }
}

sub parse_value {
    my ($name, $value) = @_;
    my $type = $OPTIONS{$name}[0];

    return encode(locale_fs => $value) if $type eq 'dir' || $type eq 'path';
    if ($type eq 'bool') {
        return 1 if $value =~ /^yes\z/i;
        return 0 if $value =~ /^no\z/i;
        return undef;
    }
    return $value =~ /^[0-9]+\z/ ? $value + 0 : undef if $type eq 'days' || $type eq 'int';
    return find_encoding($value) if $type eq 'charset';
    return exists $LEVELS{lc $value} ? lc $value : undef if $type eq 'level';
    return $value =~ /^(?:move|delete|keep)\z/i ? lc $value : undef if $type eq 'action';
    die "internal error: unknown option type $type\n";
}

sub logmsg {
    my ($level, $msg) = @_;
    return if $LEVELS{$level} > $LEVELS{$cfg{LogLevel}};
    # Names from tics and from the disk may contain control characters.
    $msg =~ s/([\x00-\x1f\x7f-\x9f])/sprintf '\\x%02X', ord $1/ge;
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

    my $buf = "\0" x 256;    # sizeof(struct statx)
    return undef if syscall($SYS_statx, AT_FDCWD, $path, 0, STATX_BTIME, $buf) != 0;
    return undef unless unpack('L', $buf) & STATX_BTIME;
    # stx_btime.tv_sec is a native s64, unpacked in halves for 32-bit perls.
    my $sec = substr($buf, STX_BTIME_OFFSET, 8);
    my ($lo, $hi) = LITTLE_ENDIAN ? unpack('Ll', $sec) : reverse unpack('lL', $sec);
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

    unless (is_regular($tic_path)) {
        logmsg('debug', "$tic_disp is not a regular file, skipping");
        return;
    }

    if (is_hidden($tic_path) && age_days($tic_path) < $cfg{WaitForHiddenTicDays}) {
        logmsg('debug', "$tic_disp is hidden, skipping");
        return;
    }

    open my $fh, '<:raw', $tic_path or do {
        logmsg('error', "cannot open $tic_disp: $!");
        return;
    };
    my $data;
    unless (defined(read $fh, $data, $cfg{MaxTicSize} + 1)) {
        logmsg('error', "cannot read $tic_disp: $!");
        return;
    }
    close $fh;
    return corrupt_tic($tic, 'size ' . (-s $tic_path) . ' exceeds MaxTicSize')
        if length $data > $cfg{MaxTicSize};
    return corrupt_tic($tic, 'contains NUL bytes') if $data =~ /\0/;

    # Keywords are case insensitive; the first occurrence wins.
    my %kw;
    (my $text = $cfg{TicCharset}->decode($data)) =~ s/^\x{FEFF}//;
    for my $line (split /\r\n|\r|\n/, $text) {
        my ($key, $value) = $line =~ /^[ \t]*(\S+)[ \t]*(.*?)[ \t]*\z/a or next;
        $kw{lc $key} //= $value;
    }

    my @names;
    for my $name (grep { defined && length } @kw{qw(lfile fullname file)}) {
        if (my $why = invalid_name($name)) {
            return corrupt_tic($tic, "file name '$name' $why");
        }
        push @names, $name unless grep { $_ eq $name } @names;
    }
    return corrupt_tic($tic, 'no File or Lfile') unless @names;
    return corrupt_tic($tic, "invalid Size '$kw{size}'")
        if defined $kw{size} && $kw{size} !~ /^[0-9]+\z/;

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
        return unless move_files($cfg{DestPath}, [$file_path, $dest_name], [$tic_path, $tic]);
        if ($cfg{TouchFiles}) {
            utime undef, undef, File::Spec->catfile($cfg{DestPath}, $dest_name)
                or logmsg('warn', "cannot touch " . disp($dest_name) . ": $!");
        }
        edit_tic($tic, $data, \%kw, $dest_name);
        return;
    }
    my $why = @why ? join('; ', @why) : 'no file ' . join(' / ', @names);

    if (age_days($tic_path) < $cfg{WaitForFileDays}) {
        logmsg('info', "$tic_disp: $why, waiting");
    }
    elsif ($cfg{DeleteOrphanTics}) {
        logmsg('info', "$tic_disp: $why, deleting tic");
        delete_file($tic_path);
    }
    else {
        logmsg('info', "$tic_disp: $why, moving tic");
        move_files($cfg{DestPath}, [$tic_path, $tic]);
    }
}

# Applies FixShortName and AddFullname to a tic already moved to DestPath
# together with its file $dest_name. $data is the original tic. On failure
# the tic is left as it is.
sub edit_tic {
    my ($tic, $data, $kw, $dest_name) = @_;
    my $tic_disp = disp($tic);
    my $long = length($kw->{lfile} // '') ? $kw->{lfile} : $kw->{fullname};
    my (%set, %add);

    # File echo processors that only know File open the file by its short
    # name, which Windows generates on its own.
    if ($IS_WIN && $cfg{FixShortName} && length($long // '') && length($kw->{file} // '')
        && fc $long ne fc $kw->{file})
    {
        my $path = File::Spec->catfile($cfg{DestPath}, $dest_name);
        my $short = Win32::GetShortPathName($path);
        $short = disp((File::Spec->splitpath($short))[2]) if defined $short;
        if (!defined $short) {
            logmsg('warn', "$tic_disp: cannot get the short name of " . disp($dest_name));
        }
        elsif ($short !~ /^[^. "*+,\/:;<=>?\[\\\]|]{1,8}(?:\.[^. "*+,\/:;<=>?\[\\\]|]{1,3})?\z/) {
            logmsg('warn', "$tic_disp: " . disp($dest_name) . ' has no short name, File left as is');
        }
        elsif (fc $short eq fc $kw->{file}) {
            logmsg('debug', "$tic_disp: short name $short matches File");
        }
        elsif (defined(my $bytes = eval { $cfg{TicCharset}->encode($short, Encode::FB_CROAK | Encode::LEAVE_SRC) })) {
            $set{file} = [$bytes, "File $kw->{file} -> $short"];
        }
        else {
            logmsg('warn', "$tic_disp: short name $short cannot be represented in TicCharset");
        }
    }

    if ($cfg{AddFullname} && length($kw->{lfile} // '') && !length($kw->{fullname} // '')) {
        if (defined $kw->{fullname}) {
            $set{fullname} = [undef, 'filled in empty Fullname'];
        }
        else {
            $add{lfile} = 'Fullname';
        }
    }

    return unless %set || %add;

    # Edit the raw bytes, so that everything else stays exactly as it was.
    my @parts = split /(\r\n|\r|\n)/, $data, -1;
    my ($eol) = $data =~ /(\r\n|\r|\n)/;
    $eol //= "\r\n";
    my (%done, %value, @what);
    for (my $i = 0; $i < @parts; $i += 2) {
        my ($pre, $key, $value) = $parts[$i] =~ /^([ \t]*(\S+)[ \t]*)(.*?)[ \t]*\z/a or next;
        $key = lc $key;
        next if $done{$key}++;
        $value{$key} = $value;
        if (my $s = $set{$key}) {
            # A value from another line is filled in after the loop.
            $s->[2] = $i;
            $s->[3] = $pre =~ /[ \t]\z/ ? $pre : "$pre ";
        }
        if (defined(my $name = delete $add{$key})) {
            my $line = "$name $value";
            push @what, "added $name";
            if ($i + 1 < @parts) {
                splice @parts, $i + 2, 0, $line, $parts[$i + 1];
            }
            else {
                push @parts, $eol, $line;
            }
            $i += 2;
        }
    }
    $set{fullname}[0] = $value{lfile} if $set{fullname};
    for my $key (sort keys %set) {
        my ($bytes, $what, $i, $pre) = @{$set{$key}};
        if (defined $i && defined $bytes) {
            $parts[$i] = $pre . $bytes;
            push @what, $what;
        }
        else {
            logmsg('warn', "$tic_disp: cannot find the line to edit ($what)");
        }
    }
    logmsg('warn', "$tic_disp: cannot find the line to edit (adding $_)") for values %add;
    return unless @what;

    my $path = File::Spec->catfile($cfg{DestPath}, $tic);
    my $tmp = "$path.tmp";
    my $fh;
    my $ok = open($fh, '>:raw', $tmp) && print({$fh} join('', @parts)) && close($fh);
    my $err = $!;
    if ($ok) {
        my @st = stat $path;
        utime @st[8, 9], $tmp if @st;
        $ok = rename $tmp, $path;
        $err = $!;
    }
    if ($ok) {
        logmsg('info', "$tic_disp: " . join(', ', @what));
    }
    else {
        logmsg('warn', "$tic_disp: cannot edit (" . join(', ', @what) . "): $err");
        close $fh if defined $fh && defined fileno $fh;
        unlink $tmp;
    }
}

# Returns the reason why a file name from a tic must not be used, or undef.
sub invalid_name {
    my ($name) = @_;
    return 'contains a path separator or drive letter' if $name =~ m{[/\\:]};
    return 'contains control characters' if $name =~ /[\x00-\x1f\x7f]/;
    return 'refers to a directory' if $name eq '.' || $name eq '..';
    return 'is a reserved device name'
        if $name =~ /^(?:CON|PRN|AUX|NUL|(?:COM|LPT)[0-9\x{B9}\x{B2}\x{B3}]|CONIN\$|CONOUT\$)(?:\.|\z)/i;
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
    my $ci = $cfg{IgnoreCase};
    my $want = $ci ? fc $name : $name;
    my (@files, @copies);
    while (defined(my $e = readdir $dh)) {
        my $have = $ci ? fc disp($e) : disp($e);
        if ($have eq $want) {
            push @files, [$e, $e];
        }
        elsif (is_renamed_copy($have, $want)) {
            push @copies, [$e, $fs_name];
        }
    }
    closedir $dh;
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
    return $i < length $name && substr($cand, $i) =~ /^[0-9A-Za-z]+\z/;
}

# Returns the reason why the file does not match the tic, or undef.
sub mismatch {
    my ($kw, $path) = @_;

    my $crc = $kw->{crc};
    return 'no Crc in tic' unless defined $crc && length $crc;
    return "invalid Crc '$crc'" unless $crc =~ /^[0-9A-Fa-f]{8}\z/;

    open my $fh, '<:raw', $path or return "cannot open: $!";
    my $size = -s $fh;
    return "size is $size, tic says $kw->{size}" if defined $kw->{size} && $kw->{size} != $size;

    my ($buf, $sum, $n) = ('', 0);
    $sum = crc32($buf, $sum) while $n = read $fh, $buf, 65536;
    return "read error: $!" unless defined $n;
    close $fh;

    $sum = sprintf '%08X', $sum;
    return "CRC is $sum, tic says " . uc $crc if $sum ne uc $crc;
    return undef;
}

# Moves [path, name] pairs to $dir, all or none. Nothing is moved if a file
# with the same name is already there, unless OverwriteExisting is set.
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
    my @moved;
    for my $f (@files) {
        my ($src, $name) = @$f;
        my $dst = File::Spec->catfile($dir, $name);
        unless (move($src, $dst)) {
            logmsg('error', 'cannot move ' . disp($src) . ' to ' . disp($dst) . ": $!");
            # Do not leave a file in DestPath without its tic.
            for my $m (reverse @moved) {
                move($m->[1], $m->[0])
                    or logmsg('error', 'cannot move ' . disp($m->[1]) . " back: $!");
            }
            return 0;
        }
        logmsg('debug', 'moved ' . disp($src) . ' to ' . disp($dst));
        push @moved, [$src, $dst];
    }
    # The file echo processor must not overlook anything in DestPath.
    if ($dir eq $cfg{DestPath}) {
        unhide($_->[1]) for @moved;
    }
    return 1;
}

sub delete_file {
    my ($path) = @_;
    if (unlink $path) {
        logmsg('debug', 'deleted ' . disp($path));
    }
    else {
        logmsg('error', 'cannot delete ' . disp($path) . ": $!");
    }
}

sub corrupt_tic {
    my ($tic, $why) = @_;
    my $tic_path = File::Spec->catfile($cfg{TicPath}, $tic);
    my $action = $cfg{CorruptTicAction};

    logmsg('warn', disp($tic) . ": corrupt tic ($why), action: $action");
    if ($action eq 'delete') {
        delete_file($tic_path);
    }
    elsif ($action eq 'move') {
        move_files($cfg{CorruptTicPath}, [$tic_path, $tic]);
    }
    return;
}
