#!/usr/bin/perl
#
# Tests for ticmambo.pl. Run with: prove t   (or perl t/ticmambo.t)
#
# Every test runs ticmambo.pl as a separate process on a fresh set of
# temporary directories.

use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec::Functions qw(catfile);
use Encode qw(encode decode);
use Encode::Locale;
use Compress::Zlib qw(crc32);
use FindBin;
use Scalar::Util ();
use File::Spec;
require Win32 if $^O eq 'MSWin32';

binmode Test::More->builder->$_, ':encoding(console_out)' for qw(output failure_output todo_output);

my $SCRIPT = catfile($FindBin::Bin, '..', 'ticmambo.pl');
my $IS_WIN = $^O eq 'MSWin32';
my $DAY    = 86400;

my ($root, $in, $dest, $corrupt, $log);

# Text file name to file system bytes.
sub fsn { encode(locale_fs => $_[0]) }

sub setup {
    $root    = tempdir(CLEANUP => 1);
    $in      = catfile($root, 'in');
    $dest    = catfile($root, 'dest');
    $corrupt = catfile($root, 'corrupt');
    $log     = catfile($root, 'ticmambo.log');
    mkdir $_ or die "mkdir $_: $!" for $in, $dest, $corrupt;
}

# Runs ticmambo with the base config plus overrides, returns the exit code.
# _preload is Perl code to run before the script, for simulations.
# _timeout is in seconds; on timeout ticmambo is killed and undef returned.
sub run_ticmambo {
    my (%opt) = @_;
    my $preload = delete $opt{_preload};
    my $timeout = delete $opt{_timeout};
    my %cfg = (
        InboundPath     => $in,
        DestPath        => $dest,
        CorruptTicPath  => $corrupt,
        LogFile         => $log,
        LogLevel        => 'debug',
        UseCreationTime => 'No',
        %opt,
    );
    my $cfg_file = catfile($root, 'ticmambo.cfg');
    open my $fh, '>:raw', $cfg_file or die $!;
    print $fh "; test config\r\n";
    for my $k (sort keys %cfg) {
        print $fh "$k $cfg{$k}\r\n" if defined $cfg{$k};
    }
    close $fh;
    my @cmd = ($^X, $SCRIPT, $cfg_file);
    if (defined $preload) {
        my $pre = put($root, 'preload.pl', "$preload;\n" . '$0 = shift; do $0; die $@ if $@; die "$0: $!" if $!;' . "\n");
        splice @cmd, 1, 0, $pre;
    }
    unless ($timeout) {
        system(@cmd);
        return $? >> 8;
    }
    # alarm does not interrupt system(), but it does interrupt waitpid.
    my $pid = fork // die "fork: $!";
    unless ($pid) {
        exec @cmd or die "exec: $!";
    }
    my $done = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $timeout;
        waitpid $pid, 0;
        alarm 0;
        1;
    };
    return $? >> 8 if $done;
    kill 'KILL', $pid;
    waitpid $pid, 0;
    return undef;
}

# Writes raw content to a file (name is text) and optionally makes it old.
sub put {
    my ($dir, $name, $content, $age) = @_;
    my $path = catfile($dir, fsn($name));
    open my $fh, '>:raw', $path or die "$path: $!";
    print $fh $content;
    close $fh;
    age($path, $age) if $age;
    return $path;
}

sub age {
    my ($path, $days) = @_;
    my $t = time - $days * $DAY - 60;
    utime $t, $t, $path or die "utime $path: $!";
}

# Builds a tic from lines; lines are byte strings.
sub tic_text { join("\r\n", @_) . "\r\n" }

sub crc { sprintf '%08X', crc32($_[0]) }

# A typical tic for $name with $content; extra lines are appended.
sub std_tic {
    my ($name, $content, @extra) = @_;
    return tic_text(
        'Area TESTAREA', 'Origin 2:5020/1', 'From 2:5020/1',
        "File $name", 'Size ' . length($content), 'Crc ' . crc($content),
        'Path 2:5020/1 1415567298', 'Seenby 2:5020/1', @extra);
}

sub has { -e catfile($_[0], fsn($_[1])) }

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $d = <$fh>;
    return $d;
}

sub log_text { decode('UTF-8', slurp($log) // '') }

# A failed check is followed at once by the log of the run it checked.
BEGIN {
    no strict 'refs';
    no warnings 'redefine';
    for my $name (qw(ok is isnt like unlike)) {
        my $orig = \&{"Test::More::$name"};
        my $wrap = sub {
            local $Test::Builder::Level = $Test::Builder::Level + 1;
            my $ok = $orig->(@_);
            my $text = $ok ? '' : log_text();
            diag("ticmambo log:\n$text") if length $text;
            return $ok;
        };
        Scalar::Util::set_prototype(\&$wrap, prototype $orig);
        *{"main::$name"} = $wrap;
    }
}

# ---------------------------------------------------------------------------

subtest 'good pair is moved, other files are left alone' => sub {
    setup();
    put($in, 'file.zip', 'hello world');
    put($in, 'a.tic', std_tic('file.zip', 'hello world'));
    put($in, 'other.zip', 'x');
    put($in, '00000001.pkt', 'x');
    is(run_ticmambo(), 0, 'exit code');
    ok(has($dest, 'file.zip'), 'file moved');
    ok(has($dest, 'a.tic'), 'tic moved');
    ok(!has($in, 'file.zip') && !has($in, 'a.tic'), 'nothing left in inbound');
    ok(has($in, 'other.zip') && has($in, '00000001.pkt'), 'unrelated files untouched');
    is(slurp(catfile($dest, 'file.zip')), 'hello world', 'content intact');
};

subtest 'tic extension is case insensitive' => sub {
    setup();
    put($in, 'file.zip', 'data');
    put($in, 'A.TIC', std_tic('file.zip', 'data'));
    put($in, 'b.Tic', std_tic('file2.zip', 'data2'));
    put($in, 'file2.zip', 'data2');
    run_ticmambo();
    ok(has($dest, 'A.TIC') && has($dest, 'b.Tic'), 'both tics processed');
};

subtest 'Crc/Size variations that match' => sub {
    setup();
    my $c = 'content';
    put($in, 'lc.zip', $c);
    put($in, 'lc.tic', tic_text('File lc.zip', 'Crc ' . lc crc($c)));
    put($in, 'nosize.zip', $c);
    put($in, 'nosize.tic', tic_text('File nosize.zip', 'Crc ' . crc($c)));
    put($in, 'zeros.zip', $c);
    put($in, 'zeros.tic', tic_text('File zeros.zip', 'Size 000' . length($c), 'Crc ' . crc($c)));
    put($in, 'empty.zip', '');
    put($in, 'empty.tic', tic_text('File empty.zip', 'Size 0', 'Crc 00000000'));
    # 'x31' has CRC 001685F0.
    put($in, 'short.zip', 'x31');
    put($in, 'short.tic', tic_text('File short.zip', 'Crc 1685f0'));
    put($in, 'zero.zip', '');
    put($in, 'zero.tic', tic_text('File zero.zip', 'Crc 0'));
    run_ticmambo();
    ok(has($dest, "$_.zip") && has($dest, "$_.tic"), "$_ moved") for qw(lc nosize zeros empty short zero);
};

subtest 'CRC-32 check value' => sub {
    # Known value, independent of the crc32 implementation used by the tests.
    setup();
    put($in, 'check.txt', '123456789');
    put($in, 'check.tic', tic_text('File check.txt', 'Size 9', 'Crc CBF43926'));
    run_ticmambo();
    ok(has($dest, 'check.txt'), '"123456789" has CRC CBF43926');
};

subtest 'large file CRC is computed over all chunks' => sub {
    setup();
    my $c = join '', map { chr($_ % 251) } 1 .. 300_000;
    put($in, 'big.bin', $c);
    put($in, 'big.tic', std_tic('big.bin', $c));
    run_ticmambo();
    ok(has($dest, 'big.bin'), 'moved');
};

for my $case (
    ['size mismatch',  sub { std_tic('f.zip', 'other length!') }],
    ['crc mismatch',   sub { tic_text('File f.zip', 'Size 4', 'Crc ' . crc('ABCD')) }],
    ['short Crc',      sub { tic_text('File f.zip', 'Crc ' . substr(crc('abcd'), 1)) }],
    ['huge Size',      sub { tic_text('File f.zip', 'Size 99999999999999999999999', 'Crc ' . crc('abcd')) }],
    )
{
    my ($label, $tic) = @$case;
    subtest "non-matching file: $label" => sub {
        setup();
        put($in, 'f.zip', 'abcd', 10);
        put($in, 'f.tic', $tic->(), 1);
        run_ticmambo(WaitForFileDays => 3);
        ok(has($in, 'f.zip') && has($in, 'f.tic'), 'young tic waits');

        age(catfile($in, 'f.tic'), 4);
        run_ticmambo(WaitForFileDays => 3, DeleteOrphanTics => 'No');
        ok(has($dest, 'f.tic') && !has($in, 'f.tic'), 'old tic moved');
        ok(has($in, 'f.zip') && !has($dest, 'f.zip'), 'file left in place');

        setup();
        put($in, 'f.zip', 'abcd', 10);
        put($in, 'f.tic', $tic->(), 4);
        run_ticmambo(WaitForFileDays => 3, DeleteOrphanTics => 'Yes');
        ok(!has($in, 'f.tic') && !has($dest, 'f.tic'), 'old tic deleted');
        ok(has($in, 'f.zip') && !has($dest, 'f.zip'), 'file left in place');
    };
}

subtest 'copies renamed by the mailer' => sub {
    my $c = 'right content';
    for my $copy ('file.zip.1', 'file.zip.12', 'file.zip.anything', 'file.zi0', 'file.zia', 'file.z0a', 'file.00z') {
        setup();
        put($in, 'file.zip', 'stale leftover');
        put($in, $copy, $c);
        put($in, 'f.tic', std_tic('file.zip', $c));
        run_ticmambo();
        is(slurp(catfile($dest, 'file.zip')), $c, "$copy moved as file.zip");
        ok(!has($in, $copy), "$copy gone from inbound");
        is(slurp(catfile($in, 'file.zip')), 'stale leftover', "stale file.zip left alone ($copy)");
    }

    # The file itself is checked before its copies, whatever the order in
    # the directory; several copies make an accidental pass unlikely.
    for my $ic (qw(No Yes)) {
        setup();
        my @copies = ('file.zip.0', 'file.zip.1', 'file.zip.9', 'file.zi0', 'file.zia', 'file.z0a');
        put($in, $_, $c) for @copies;
        put($in, $ic eq 'No' ? 'file.zip' : 'FILE.ZIP', $c);
        put($in, 'f.tic', std_tic('file.zip', $c));
        run_ticmambo(IgnoreCase => $ic);
        ok(!has($in, 'file.zip') && !has($in, 'FILE.ZIP'), "IgnoreCase $ic: the file itself moved, not a copy");
        is(scalar(grep { has($in, $_) } @copies), scalar @copies, "IgnoreCase $ic: all copies left alone");
    }

    setup();
    put($in, 'file.zip.1', 'wrong 1');
    put($in, 'file.zip.2', $c);
    put($in, 'file.zip.3', 'wrong 3');
    put($in, 'f.tic', std_tic('file.zip', $c));
    run_ticmambo();
    is(slurp(catfile($dest, 'file.zip')), $c, 'only copies, the matching one moved');
    ok(has($in, 'file.zip.1') && has($in, 'file.zip.3'), 'other copies untouched');

    setup();
    put($in, 'file.zip', 'wrong');
    put($in, "file.zip.$_", "wrong $_") for 1 .. 5;
    put($in, 'f.tic', std_tic('file.zip', $c));
    run_ticmambo(WaitForFileDays => 3);
    ok(has($in, 'f.tic'), 'no matching file: tic waits');
    like(log_text(), qr/f\.tic: File file\.zip: size is 5, tic says 13, waiting/, 'no matching file: reason logged');
    unlike(log_text(), qr/file\.zip\.\d/, 'no matching file: copies not mentioned');

    setup();
    put($in, "file.zip.$_", "wrong $_") for 1 .. 5;
    put($in, 'f.tic', std_tic('file.zip', $c));
    run_ticmambo(WaitForFileDays => 3);
    like(log_text(), qr/f\.tic: File file\.zip: not found, waiting/, 'only non-matching copies: not found');
    unlike(log_text(), qr/file\.zip\.\d/, 'only non-matching copies: copies not mentioned');

    setup();
    put($in, 'long name.zip', 'wrong');
    put($in, 'f.tic', tic_text('File LONGNA~1.ZIP', 'Lfile long name.zip', 'Crc ' . crc($c)));
    run_ticmambo(WaitForFileDays => 3);
    like(log_text(), qr/f\.tic: Lfile long name\.zip: CRC is [0-9A-F]{8}, tic says [0-9A-F]{8}; File LONGNA~1\.ZIP: not found, waiting/,
        'both names reported');

    # With IgnoreCase No, File that differs from Fullname only in case is a
    # different name, and so are its copies; with IgnoreCase Yes File is
    # not looked for again, and its copies are copies of Fullname.
    setup();
    put($in, 'FILE.ZIP', $c);
    put($in, 'f.tic', tic_text('File FILE.ZIP', 'Fullname file.zip', 'Crc ' . crc($c)));
    run_ticmambo(IgnoreCase => 'No');
    ok(has($dest, 'FILE.ZIP') && has($dest, 'f.tic'), 'IgnoreCase No: File same as Fullname but for case found');

    setup();
    put($in, 'FILE.ZIP', 'wrong');
    put($in, 'FILE.ZIP.1', $c);
    put($in, 'f.tic', tic_text('File FILE.ZIP', 'Fullname file.zip', 'Crc ' . crc($c)));
    run_ticmambo(IgnoreCase => 'No');
    is(slurp(catfile($dest, 'FILE.ZIP')), $c, 'IgnoreCase No: copy of File same as Fullname but for case moved');

    setup();
    put($in, 'FILE.ZIP', 'wrong');
    put($in, 'FILE.ZIP.1', $c);
    put($in, 'f.tic', tic_text('File FILE.ZIP', 'Fullname file.zip', 'Crc ' . crc($c)));
    run_ticmambo(IgnoreCase => 'Yes');
    is(slurp(catfile($dest, 'file.zip')), $c, 'IgnoreCase Yes: copy of Fullname moved');

    setup();
    put($in, 'FILE.ZIP', 'wrong');
    put($in, 'f.tic', tic_text('File FILE.ZIP', 'Fullname file.zip', 'Crc ' . crc($c)));
    run_ticmambo(IgnoreCase => 'Yes', WaitForFileDays => 3);
    like(log_text(), qr/f\.tic: Fullname file\.zip: CRC is [0-9A-F]{8}, tic says [0-9A-F]{8}, waiting/,
        'IgnoreCase Yes: File same as Fullname but for case not looked for again');

    setup();
    put($in, 'README.1', $c);
    put($in, 'Long Name.tar.gz.1', $c);
    put($in, 'a.tic', std_tic('README', $c));
    put($in, 'b.tic', tic_text('File LONGNA~1.GZ', 'Lfile Long Name.tar.gz', 'Crc ' . crc($c)));
    run_ticmambo();
    ok(has($dest, 'README'), 'name without extension');
    ok(has($dest, 'Long Name.tar.gz'), 'Lfile copy');

    setup();
    # Windows drops the trailing dot of 'file.zip.' and would create file.zip.
    put($in, $_, $c) for 'file.zip1', 'xfile.zip.1', 'file.zi', 'file.zipx', 'file.zi_', 'file.zi0.1',
        $IS_WIN ? () : 'file.zip.';
    put($in, 'f.tic', std_tic('file.zip', $c));
    run_ticmambo(WaitForFileDays => 3);
    ok(has($in, 'f.tic'), 'similar names that are not copies are ignored');
    ok(!has($dest, 'file.zip'), 'nothing moved');

    setup();
    put($in, 'FILE.ZIP.1', $c);
    put($in, 'f.tic', std_tic('file.zip', $c));
    run_ticmambo(IgnoreCase => 'No', WaitForFileDays => 3);
    ok(has($in, 'FILE.ZIP.1') && has($in, 'f.tic'), 'No: copy in other case ignored');
    run_ticmambo(IgnoreCase => 'Yes');
    ok(has($dest, 'file.zip'), 'Yes: copy in other case moved under tic name');

    setup();
    put($in, 'file.zip.1', $c);
    put($in, 'f.tic', std_tic('file.zip', $c));
    put($dest, 'file.zip', 'previous');
    run_ticmambo();
    ok(has($in, 'file.zip.1') && has($in, 'f.tic'), 'name taken in DestPath: skipped');
    is(slurp(catfile($dest, 'file.zip')), 'previous', 'DestPath file intact');
};

subtest 'copies of Lfile are looked for before File' => sub {
    # A File that looks like a copy of Lfile is File itself.
    setup();
    put($in, 'file.zi0', 'x');
    put($in, 'f.tic', tic_text('File file.zi0', 'Lfile file.zip', 'Crc ' . crc('x')));
    run_ticmambo();
    ok(has($dest, 'file.zi0') && !has($dest, 'file.zip'), 'File found by its own name');

    setup();
    put($in, 'LONGNA~1.ZIP', 'x');
    put($in, 'long name.zip.1', 'x');
    put($in, 'f.tic', tic_text('File LONGNA~1.ZIP', 'Lfile long name.zip', 'Crc ' . crc('x')));
    run_ticmambo();
    ok(has($dest, 'long name.zip') && has($in, 'LONGNA~1.ZIP'), 'copy of Lfile moved');
};

subtest 'several tics for one file: the matching one wins' => sub {
    for my $order (['a.tic', 'b.tic'], ['b.tic', 'a.tic']) {
        my ($bad, $good) = @$order;
        setup();
        put($in, 'f.zip', 'real content', 1);
        put($in, $bad,  tic_text('File f.zip', 'Size 12', 'Crc 12345678'), 1);
        put($in, $good, std_tic('f.zip', 'real content'), 1);
        run_ticmambo(WaitForFileDays => 7);
        ok(has($dest, 'f.zip') && has($dest, $good), "good tic $good moved with file");
        ok(has($in, $bad) && !has($dest, $bad), "bad tic $bad stays waiting");
    }
};

subtest 'orphan tics' => sub {
    setup();
    put($in, 'young.tic', std_tic('none.zip', 'x'), 1);
    put($in, 'old.tic', std_tic('none.zip', 'x'), 4);
    run_ticmambo(WaitForFileDays => 3, DeleteOrphanTics => 'No');
    ok(has($in, 'young.tic'), 'young orphan waits');
    ok(has($dest, 'old.tic'), 'old orphan moved to dest');

    setup();
    put($in, 'old.tic', std_tic('none.zip', 'x'), 4);
    run_ticmambo(WaitForFileDays => 3, DeleteOrphanTics => 'Yes');
    ok(!has($in, 'old.tic') && !has($dest, 'old.tic'), 'old orphan deleted');

    setup();
    put($in, 'now.tic', std_tic('none.zip', 'x'));
    run_ticmambo(WaitForFileDays => 0);
    ok(has($dest, 'now.tic'), 'WaitForFileDays 0 handles orphans immediately');
};

subtest 'tics without file names are corrupt' => sub {
    setup();
    put($in, 'nofile.tic', tic_text('Area X', 'Crc 12345678'));
    put($in, 'empty.tic', '');
    put($in, 'blank.tic', "\r\n\r\n   \t\r\n");
    put($in, 'emptyval.tic', tic_text('File', 'Lfile   ', 'Crc'));
    run_ticmambo(WaitForFileDays => 3);
    ok(has($corrupt, $_), "$_ in CorruptTicPath") for qw(nofile.tic empty.tic blank.tic emptyval.tic);
};

subtest 'tics without a valid Crc are corrupt' => sub {
    setup();
    put($in, 'f.zip', 'abcd');
    put($in, 'none.tic', tic_text('File f.zip', 'Size 4'));
    put($in, 'empty.tic', tic_text('File f.zip', 'Crc'));
    put($in, 'long.tic', tic_text('File f.zip', 'Crc 0' . crc('abcd')));
    put($in, 'nonhex.tic', tic_text('File f.zip', 'Crc XYZXYZXY'));
    put($in, 'junk.tic', tic_text('File f.zip', 'Crc ' . crc('abcd') . ' junk'));
    put($in, 'prefix.tic', tic_text('File f.zip', 'Crc 0x' . crc('abcd')));
    run_ticmambo(WaitForFileDays => 3);
    ok(has($corrupt, $_), "$_ in CorruptTicPath") for qw(none.tic empty.tic long.tic nonhex.tic junk.tic prefix.tic);
    ok(has($in, 'f.zip'), 'file left in place');
};

SKIP: {
    skip 'no /dev/urandom', 1 unless -r '/dev/urandom';
    subtest 'random binary garbage without NUL bytes' => sub {
        setup();
        open my $r, '<:raw', '/dev/urandom' or die $!;
        for my $i (1 .. 20) {
            read $r, my $junk, 4000;
            $junk =~ tr/\0//d;
            put($in, "junk$i.tic", $junk);
        }
        close $r;
        is(run_ticmambo(MaxTicSize => 65536), 0, 'exit code');
        my @left = grep { has($in, "junk$_.tic") || has($corrupt, "junk$_.tic") } 1 .. 20;
        is(scalar @left, 20, 'every junk tic is either waiting or in CorruptTicPath');
    };
}

subtest 'Lfile, Fullname and File' => sub {
    setup();
    put($in, 'Long File Name.zip', 'long');
    # Not LONGFI~1.ZIP: on Windows that may be the short name of the file above.
    put($in, 'LFN.ZIP', 'short');
    put($in, '1.tic', tic_text('File LFN.ZIP', 'Lfile Long File Name.zip', 'Crc ' . crc('long')));
    run_ticmambo();
    ok(has($dest, 'Long File Name.zip'), 'Lfile preferred');
    ok(has($in, 'LFN.ZIP'), 'short name untouched');

    setup();
    put($in, 'SHORT.ZIP', 'short');
    put($in, '2.tic', tic_text('File SHORT.ZIP', 'Lfile Not here.zip', 'Crc ' . crc('short')));
    run_ticmambo();
    ok(has($dest, 'SHORT.ZIP'), 'falls back to File');

    setup();
    put($in, 'Full Name.zip', 'full');
    put($in, '3.tic', tic_text('Fullname Full Name.zip', 'Crc ' . crc('full')));
    run_ticmambo();
    ok(has($dest, 'Full Name.zip'), 'Fullname is an alias for Lfile');

    setup();
    put($in, 'odd.', 'dot');
    put($in, '4.tic', tic_text('Lfile odd.', 'Crc ' . crc('dot')));
    run_ticmambo();
    ok(has($dest, 'odd.'), 'trailing dot in a long name is fine') unless $IS_WIN;
    ok(!has($corrupt, '4.tic'), 'not considered corrupt');
};

subtest 'first keyword occurrence wins' => sub {
    setup();
    put($in, 'f.zip', 'abc');
    put($in, 'f.tic', tic_text('File f.zip', 'Crc ' . crc('abc'), 'File g.zip', 'Crc 00000000'));
    run_ticmambo();
    ok(has($dest, 'f.zip'), 'first File and Crc used');
};

subtest 'line endings and keyword formatting' => sub {
    setup();
    my $c = 'payload';
    my $crc = crc($c);
    my %tics = (
        'lf.tic'    => "File lf.zip\nCrc $crc\n",
        'cr.tic'    => "File cr.zip\rCrc $crc\r",
        'mixed.tic' => "File mixed.zip\r\nSize 7\nCrc $crc\r",
        'case.tic'  => "fIlE case.zip\r\ncRc $crc",
        'space.tic' => "  \tFile\t\tspace.zip  \t\r\n   CRC   $crc   \r\n",
    );
    for my $t (keys %tics) {
        (my $f = $t) =~ s/\.tic$/.zip/;
        put($in, $f, $c);
        put($in, $t, $tics{$t});
    }
    run_ticmambo();
    for my $t (sort keys %tics) {
        (my $f = $t) =~ s/\.tic$/.zip/;
        ok(has($dest, $f) && has($dest, $t), $t);
    }
};

subtest 'IgnoreCase' => sub {
    # The same on every file system, Windows included.
    setup();
    put($in, 'file.zip', 'x');
    put($in, 'f.tic', tic_text('File FILE.ZIP', 'Crc ' . crc('x')));
    run_ticmambo(IgnoreCase => 'No', WaitForFileDays => 3);
    ok(has($in, 'f.tic') && has($in, 'file.zip'), 'No: different case is not found');
    run_ticmambo(IgnoreCase => 'Yes');
    ok(has($dest, 'file.zip'), 'Yes: found and moved under its own name');

    setup();
    put($in, 'file.zip', 'x');
    put($in, 'f.tic', tic_text('File FILE.ZIP', 'Crc ' . crc('x')));
    run_ticmambo(WaitForFileDays => 3);
    if ($IS_WIN) {
        ok(has($dest, 'file.zip'), 'default on Windows: Yes');
    }
    else {
        ok(has($in, 'file.zip') && has($in, 'f.tic'), 'default outside Windows: No');
    }
};

subtest 'non-ASCII names' => sub {
    setup();
    put($in, 'Тест.zip', 'kirill');
    put($in, 'a.tic', tic_text('File ' . encode('cp866', 'Тест.zip'), 'Crc ' . crc('kirill')));
    run_ticmambo();
    ok(has($dest, 'Тест.zip'), 'cp866 name found');

    setup();
    put($in, 'тЕСТ.ZIP', 'kirill');
    put($in, 'b.tic', tic_text('Lfile ' . encode('cp866', 'Тест.zip'), 'Crc ' . crc('kirill')));
    run_ticmambo(IgnoreCase => 'Yes');
    ok(has($dest, 'тЕСТ.ZIP'), 'case insensitive Cyrillic match');

    setup();
    put($in, 'Ёжик.rar', 'hedgehog');
    put($in, 'c.tic', tic_text('File ' . encode('cp1251', 'Ёжик.rar'), 'Crc ' . crc('hedgehog')));
    run_ticmambo(TicCharset => 'cp1251');
    ok(has($dest, 'Ёжик.rar'), 'TicCharset cp1251');

    setup();
    put($in, 'Тест.zip', 'kirill');
    put($in, 'd.tic', tic_text('File ' . encode('cp866', 'Тест.zip'), 'Crc ' . crc('kirill')));
    run_ticmambo(TicCharset => 'cp1251', WaitForFileDays => 3);
    ok(has($in, 'd.tic'), 'wrong TicCharset: file not found, tic waits');
};

my $nfd = "\x{0438}\x{0306}\x{0436}\x{0438}\x{043A}.zip";    # и + breve
my $nfc = "\x{0439}\x{0436}\x{0438}\x{043A}.zip";
SKIP: {
    # Not on Windows: the ANSI code page has no combining characters.
    skip 'decomposed names cannot be represented in the file system encoding', 1
        unless defined eval { encode(locale_fs => $nfd, Encode::FB_CROAK | Encode::LEAVE_SRC) };
    subtest 'names in another Unicode normalization form' => sub {
        # As on macOS HFS+: the name on disk is decomposed, the one in the tic
        # is not.
        for my $ic (qw(No Yes)) {
            setup();
            put($in, $nfd, 'x');
            put($in, 'f.tic', tic_text('File ' . encode('cp866', $nfc), 'Crc ' . crc('x')));
            run_ticmambo(IgnoreCase => $ic);
            ok(has($dest, $nfd) && has($dest, 'f.tic'), "IgnoreCase $ic: found");
        }

        setup();
        put($in, $nfc, 'x');
        put($in, 'f.tic', tic_text('File ' . encode('UTF-8', $nfd), 'Crc ' . crc('x')));
        run_ticmambo(TicCharset => 'UTF-8');
        ok(has($dest, $nfc), 'decomposed name in the tic: found');

        setup();
        put($in, "$nfd.1", 'x');
        put($in, 'f.tic', tic_text('File ' . encode('cp866', $nfc), 'Crc ' . crc('x')));
        run_ticmambo();
        ok(has($dest, $nfc), 'renamed copy found, moved under the name from the tic');
    };
}

SKIP: {
    skip 'the file system encoding is set by the locale on Unix only', 1 if $IS_WIN;
    subtest 'name that cannot be represented in the file system encoding' => sub {
        local $ENV{LC_ALL} = 'C';
        my $tic = tic_text('File TEST.ZIP', 'Lfile ' . encode('cp866', 'Тест.zip'), 'Crc ' . crc('x'));
        setup();
        put($in, 'f.tic', $tic, 10);
        is(run_ticmambo(WaitForFileDays => 3, DeleteOrphanTics => 'Yes'), 0, 'exit code');
        ok(has($in, 'f.tic'), 'old tic not taken for an orphan');
        like(log_text(), qr/\[ERROR\] f\.tic: Lfile .*: cannot be represented in the file system encoding; File TEST\.ZIP: not found, skipping/,
            'error logged');

        setup();
        put($in, 'TEST.ZIP', 'x');
        put($in, 'f.tic', $tic, 10);
        run_ticmambo(WaitForFileDays => 3, DeleteOrphanTics => 'Yes');
        ok(has($dest, 'TEST.ZIP') && has($dest, 'f.tic'), 'found by the other name');
    };
}

subtest 'TicCharset with NUL bytes' => sub {
    # NUL characters are looked for in the decoded tic, not in its bytes.
    setup();
    put($in, 'f.zip', 'x');
    put($in, 'f.tic', encode('UTF-16LE', std_tic('f.zip', 'x')));
    run_ticmambo(TicCharset => 'UTF-16LE');
    ok(has($dest, 'f.zip') && has($dest, 'f.tic'), 'UTF-16LE tic: pair moved');

    setup();
    put($in, 'f.tic', encode('UTF-16LE', std_tic('f.zip', 'x') . "\0"));
    run_ticmambo(TicCharset => 'UTF-16LE');
    ok(has($corrupt, 'f.tic'), 'UTF-16LE tic with a NUL character: corrupt');
};

subtest 'tic not valid in TicCharset is left alone' => sub {
    my $tic = tic_text('File f.zip', "Desc caf\xE9", 'Crc ' . crc('x'));
    for my $file (0, 1) {
        my $what = $file ? 'matching file' : 'no file';
        setup();
        put($in, 'f.zip', 'x') if $file;
        put($in, 'f.tic', $tic, 10);
        is(run_ticmambo(TicCharset => 'UTF-8', WaitForFileDays => 3, DeleteOrphanTics => 'Yes'), 0, "$what: exit code");
        ok(has($in, 'f.tic') && !has($dest, 'f.tic'), "$what: tic left in place");
        like(log_text(), qr/\[ERROR\] f\.tic: not valid in TicCharset, skipping/, "$what: error logged");
    }
};

SKIP: {
    skip 'Win32 only', 1 unless $IS_WIN;
    subtest 'names impossible on Windows' => sub {
        setup();
        put($in, 'file.zip', 'x');
        put($in, 'f.tic', tic_text('Lfile file.zip.', 'Crc ' . crc('x')), 10);
        is(run_ticmambo(WaitForFileDays => 3, DeleteOrphanTics => 'Yes'), 0, 'dot at the end: exit code');
        ok(has($in, 'f.tic') && has($in, 'file.zip'), 'dot at the end: old tic not taken for an orphan');
        like(log_text(), qr/\[ERROR\] f\.tic: Lfile file\.zip\.: ends with a dot or space/, 'dot at the end: error logged');

        setup();
        put($in, 'f.tic', tic_text('Lfile what?.zip', 'Crc ' . crc('x')), 10);
        is(run_ticmambo(WaitForFileDays => 3, DeleteOrphanTics => 'Yes'), 0, 'question mark: exit code');
        ok(has($in, 'f.tic'), 'question mark: old tic not taken for an orphan');
        like(log_text(), qr/\[ERROR\] f\.tic: Lfile what\?\.zip: contains one of/, 'question mark: error logged');
    };
}

my @evil_names = (
    '../victim', '..\\victim', '../../../../../../etc/passwd', '/etc/passwd',
    '\\windows\\win.ini', 'C:victim', 'C:\\victim', 'c:/victim', 'file.zip:stream',
    '..', '.', "a\x01b", "tab\there", "esc\x1b[2J", "del\x7f",
    'CON', 'con', 'NUL.txt', 'aux.zip', 'COM1', 'lpt9.bin', 'PRN', 'CONIN$',
    'sub/file.zip', '\\\\server\\share\\x',
);

for my $action (qw(Move Delete Keep)) {
    subtest "corrupt file names, CorruptTicAction $action" => sub {
        setup();
        my $victim = put($root, 'victim', 'secret');
        my $i = 0;
        for my $n (@evil_names) {
            $i++;
            put($in, "evil$i.tic", tic_text("File $n", 'Crc ' . crc('secret')));
            $i++;
            put($in, "evil$i.tic", tic_text('File OK.ZIP', "Lfile $n", 'Crc ' . crc('secret')));
        }
        put($in, 'OK.ZIP', 'secret');
        is(run_ticmambo(CorruptTicAction => $action), 0, 'exit code');
        is(slurp($victim), 'secret', 'victim outside inbound untouched');
        ok(has($in, 'OK.ZIP'), 'innocent file referenced by corrupt tic untouched');
        for my $n (1 .. $i) {
            my $t = "evil$n.tic";
            if ($action eq 'Move') {
                ok(has($corrupt, $t) && !has($in, $t), "$t in CorruptTicPath");
            }
            elsif ($action eq 'Delete') {
                ok(!has($corrupt, $t) && !has($in, $t), "$t deleted");
            }
            else {
                ok(!has($corrupt, $t) && has($in, $t), "$t kept");
            }
        }
        my @dest = grep { !/^\.\.?$/ } do { opendir(my $d, $dest); readdir $d };
        is(scalar @dest, 0, 'nothing reached dest');
        unlike(log_text(), qr/[\x00-\x09\x0b\x0c\x0e-\x1f\x7f]/, 'no control characters in the log');
    };
}

subtest 'invalid Size makes the tic corrupt' => sub {
    my $crc = crc('abcd');
    my %tics = (
        'k.tic'     => "Size 4k",
        'neg.tic'   => "Size -4",
        'plus.tic'  => "Size +4",
        'hex.tic'   => "Size 0x4",
        'float.tic' => "Size 4.0",
        'space.tic' => "Size 4 bytes",
        'empty.tic' => "Size",
        'blank.tic' => "Size   \t",
        'arab.tic'  => "Size \xD9\xA4",
        'wide.tic'  => "Size \xEF\xBC\x94",
    );
    for my $charset (qw(cp866 UTF-8)) {
        setup();
        put($in, 'f.zip', 'abcd');
        put($in, $_, tic_text('File f.zip', $tics{$_}, "Crc $crc")) for keys %tics;
        run_ticmambo(TicCharset => $charset);
        ok(has($corrupt, $_), "$charset, $_: in CorruptTicPath") for sort keys %tics;
        ok(has($in, 'f.zip'), "$charset: file untouched");
    }
};

subtest 'NUL bytes and oversized tics are corrupt' => sub {
    setup();
    put($in, 'f.zip', 'x');
    # Not nul.tic: NUL is a device on Windows, whatever the extension.
    put($in, 'zero.tic', "File f.zip\r\nCrc " . crc('x') . "\r\n\0");
    put($in, 'big.tic', std_tic('f.zip', 'x') . ('Ldesc ' . ('x' x 70) . "\r\n") x 1000);
    put($in, 'limit.tic', std_tic('g.zip', 'x'));
    run_ticmambo(MaxTicSize => 2000);
    ok(has($corrupt, 'zero.tic'), 'tic with NUL in CorruptTicPath');
    ok(has($corrupt, 'big.tic'), 'oversized tic in CorruptTicPath');
    ok(has($in, 'f.zip'), 'file untouched');
    ok(has($in, 'limit.tic'), 'small tic processed normally');
};

SKIP: {
    skip 'no /dev/urandom', 1 unless -r '/dev/urandom';
    subtest 'random binary tic' => sub {
        setup();
        open my $r, '<:raw', '/dev/urandom' or die $!;
        read $r, my $junk, 1_000_000;
        close $r;
        put($in, 'rnd.tic', $junk);
        put($in, 'rnd2.tic', "File x\r\n\0" . substr($junk, 0, 1000));
        is(run_ticmambo(), 0, 'exit code');
        ok(has($corrupt, 'rnd.tic'), '1 MB random tic moved to CorruptTicPath');
        ok(has($corrupt, 'rnd2.tic'), 'small binary tic moved to CorruptTicPath');
    };
}

SKIP: {
    skip 'sparse files are not cheap here', 1 if $IS_WIN;
    subtest '2+ GB tic' => sub {
        setup();
        my $p = catfile($in, 'huge.tic');
        open my $fh, '>:raw', $p or die $!;
        print $fh "File x.zip\r\n";
        truncate $fh, 2**31 + 4096 or die "truncate: $!";
        close $fh;
        my $t0 = time;
        is(run_ticmambo(), 0, 'exit code');
        ok(time - $t0 < 30, 'did not read the whole file');
        ok(has($corrupt, 'huge.tic'), 'moved to CorruptTicPath');
    };
}

SKIP: {
    skip 'no symlinks/fifos on Win32', 1 if $IS_WIN;
    subtest 'special files' => sub {
        setup();
        require POSIX;
        my $victim = put($root, 'victim', 'secret');
        symlink $victim, catfile($in, 'link.zip') or die $!;
        put($in, 'link.tic', std_tic('link.zip', 'secret'), 10);
        symlink '/dev/urandom', catfile($in, 'urandom.tic') or die $!;
        symlink $victim, catfile($in, 'victim.tic') or die $!;
        POSIX::mkfifo(catfile($in, 'fifo.tic'), 0600) or die $!;
        POSIX::mkfifo(catfile($in, 'fifo.zip'), 0600) or die $!;
        put($in, 'fifo-ref.tic', std_tic('fifo.zip', ''), 10);
        mkdir catfile($in, 'dir.tic');
        mkdir catfile($in, 'dir.zip');
        put($in, 'dir-ref.tic', std_tic('dir.zip', ''), 10);

        is(run_ticmambo(WaitForFileDays => 3, _timeout => 30), 0, 'finished without hanging');
        is(slurp($victim), 'secret', 'victim untouched');
        # The tics are old, so they are moved alone as orphans.
        ok(-l catfile($in, 'link.zip') && !has($dest, 'link.zip') && has($dest, 'link.tic'), 'symlinked data file not used');
        ok(-l catfile($in, 'urandom.tic') && -l catfile($in, 'victim.tic'), 'symlinked tics ignored');
        ok(-p catfile($in, 'fifo.tic'), 'fifo tic ignored');
        ok(-p catfile($in, 'fifo.zip') && !has($dest, 'fifo.zip') && has($dest, 'fifo-ref.tic'), 'fifo data file not used');
        ok(-d catfile($in, 'dir.tic') && -d catfile($in, 'dir.zip') && has($dest, 'dir-ref.tic'), 'directories ignored');
        like(log_text(), qr/\[DEBUG\] dir\.zip is not a regular file, skipping/, 'directory data file logged');
    };
}

subtest 'existing files in DestPath' => sub {
    setup();
    put($in, 'f.zip', 'new');
    put($in, 'f.tic', std_tic('f.zip', 'new'));
    put($dest, 'f.zip', 'old');
    is(run_ticmambo(), 2, 'file exists in dest: exit code');
    ok(has($in, 'f.zip') && has($in, 'f.tic'), 'file exists in dest: pair skipped');
    is(slurp(catfile($dest, 'f.zip')), 'old', 'dest file not overwritten');

    setup();
    put($in, 'f.zip', 'new');
    put($in, 'f.tic', std_tic('f.zip', 'new'));
    put($dest, 'f.tic', 'old tic');
    is(run_ticmambo(), 2, 'tic exists in dest: exit code');
    ok(has($in, 'f.zip') && has($in, 'f.tic'), 'tic exists in dest: pair skipped');

    setup();
    put($in, 'f.tic', std_tic('f.zip', 'new'), 10);
    put($dest, 'f.tic', 'old tic');
    is(run_ticmambo(WaitForFileDays => 3), 2, 'orphan tic exists in dest: exit code');
    ok(has($in, 'f.tic'), 'orphan tic exists in dest: tic skipped');

    setup();
    put($in, 'f.zip', 'new');
    put($in, 'f.tic', std_tic('f.zip', 'new'));
    put($dest, 'f.zip', 'old');
    put($dest, 'f.tic', 'old tic');
    is(run_ticmambo(OverwriteExisting => 'Yes'), 0, 'OverwriteExisting: exit code');
    is(slurp(catfile($dest, 'f.zip')), 'new', 'OverwriteExisting: file replaced');
    is(slurp(catfile($dest, 'f.tic')), std_tic('f.zip', 'new'), 'OverwriteExisting: tic replaced');

    # The directory is reported even if the other name is taken too.
    setup();
    put($in, 'f.zip', 'x');
    put($in, 'f.tic', std_tic('f.zip', 'x'));
    put($dest, 'f.zip', 'old');
    mkdir catfile($dest, 'f.tic') or die $!;
    is(run_ticmambo(), 0, 'directory and file in dest: exit code');
    like(log_text(), qr/\[ERROR\] f\.tic is a directory in /, 'directory and file in dest: directory reported');

    # move() would put the file into the directory.
    for my $overwrite (qw(Yes No)) {
        setup();
        put($in, 'f.zip', 'x');
        put($in, 'f.tic', std_tic('f.zip', 'x'));
        mkdir catfile($dest, 'f.zip') or die $!;
        is(run_ticmambo(OverwriteExisting => $overwrite), 0, "directory in dest, OverwriteExisting $overwrite: exit code");
        ok(has($in, 'f.zip') && has($in, 'f.tic') && !has($dest, 'f.tic'),
            "directory in dest, OverwriteExisting $overwrite: pair skipped");
        like(log_text(), qr/\[ERROR\] f\.zip is a directory in /, "directory in dest, OverwriteExisting $overwrite: logged");
    }

    setup();
    put($in, 'evil.tic', tic_text('File ../x'));
    my $sub = 'sub { $! = 13; 0 }';
    is(run_ticmambo(_preload => "require File::Copy; no warnings; *File::Copy::move = $sub"), 0,
        'corrupt tic cannot be moved to CorruptTicPath: exit code');
    ok(has($in, 'evil.tic'), 'corrupt tic cannot be moved to CorruptTicPath: left in place');

    setup();
    put($in, 'evil.tic', tic_text('File ../x'));
    put($corrupt, 'evil.tic', 'previous');
    is(run_ticmambo(), 0, 'corrupt tic exists in CorruptTicPath: exit code');
    ok(has($in, 'evil.tic'), 'corrupt tic kept when CorruptTicPath already has one');
};

subtest 'pair is moved all or none' => sub {
    # The tic cannot be moved; the file that was already moved must come back.
    setup();
    put($in, 'f.zip', 'x');
    put($in, 'f.tic', std_tic('f.zip', 'x'));
    my $sub = 'sub { if ($_[0] =~ /\.tic\z/) { $! = 13; return 0 } goto &$orig }';
    is(run_ticmambo(_preload => "require File::Copy; no warnings; my \$orig = \\&File::Copy::move; *File::Copy::move = $sub"),
        2, 'exit code');
    ok(has($in, 'f.zip') && has($in, 'f.tic'), 'file moved back, tic in place');
    ok(!has($dest, 'f.zip') && !has($dest, 'f.tic'), 'nothing in DestPath');
    like(log_text(), qr/cannot move \S*f\.tic to/, 'error logged');
};

subtest 'InboundPath cannot be read' => sub {
    setup();
    put($in, 'f.zip', 'x');
    put($in, 'f.tic', std_tic('f.zip', 'x'));
    is(run_ticmambo(_preload => 'package Fake; *main::opendir = sub { $! = 13; 0 }; package main'),
        2, 'exit code');
    ok(has($in, 'f.tic') && has($in, 'f.zip'), 'nothing moved');
    like(log_text(), qr/\[ERROR\] cannot read InboundPath/, 'error logged');
};

subtest 'InboundPath cannot be read when looking for the file' => sub {
    setup();
    put($in, 'f.zip', 'x');
    put($in, 'f.tic', std_tic('f.zip', 'x'), 10);
    # The first opendir is the main loop; the next ones fail. The override
    # is imported into main only: a global one would break Cwd.
    my $sub = 'sub { if ($n++) { $! = 13; return 0 } CORE::opendir($_[0], $_[1]) }';
    is(run_ticmambo(DeleteOrphanTics => 'Yes', WaitForFileDays => 3,
        _preload => "package Fake; my \$n = 0; *main::opendir = $sub; package main"), 2, 'exit code');
    ok(has($in, 'f.tic') && has($in, 'f.zip'), 'old tic not taken for an orphan');
    like(log_text(), qr/\[ERROR\] f\.tic: cannot read InboundPath [^\n]*, skipping/, 'error logged');
};

SKIP: {
    skip 'needs Unix permissions and no root', 1 if $IS_WIN || $> == 0;
    subtest 'unreadable tic or file' => sub {
        setup();
        put($in, 'f.zip', 'x');
        chmod 0, put($in, 'f.tic', std_tic('f.zip', 'x'));
        is(run_ticmambo(), 2, 'unreadable tic: exit code');
        ok(has($in, 'f.tic') && has($in, 'f.zip'), 'unreadable tic: left in place');

        # An old tic is not taken for an orphan while a file cannot be checked.
        for my $delete (qw(Yes No)) {
            setup();
            chmod 0, put($in, 'f.zip', 'x');
            put($in, 'f.tic', std_tic('f.zip', 'x'), 10);
            is(run_ticmambo(WaitForFileDays => 3, DeleteOrphanTics => $delete), 2,
                "unreadable file, DeleteOrphanTics $delete: exit code");
            ok(has($in, 'f.tic') && has($in, 'f.zip'), "unreadable file, DeleteOrphanTics $delete: left in place");
            like(log_text(), qr/\[ERROR\] cannot check f\.zip/, "unreadable file, DeleteOrphanTics $delete: error logged");
        }

        # readdir works, lstat fails.
        setup();
        put($in, 'f.zip', 'x');
        put($in, 'f.tic', std_tic('f.zip', 'x'));
        chmod 0444, $in;
        my $rc = run_ticmambo();
        chmod 0755, $in;
        is($rc, 2, 'InboundPath not searchable: exit code');
        ok(has($in, 'f.tic') && has($in, 'f.zip'), 'InboundPath not searchable: left in place');
        like(log_text(), qr/\[ERROR\] cannot stat f\.tic/, 'InboundPath not searchable: error logged');

        setup();
        chmod 0, put($in, 'f.zip.1', 'x');
        put($in, 'f.tic', std_tic('f.zip', 'x'), 10);
        is(run_ticmambo(WaitForFileDays => 3), 2, 'unreadable renamed copy: exit code');
        ok(has($in, 'f.tic') && !has($dest, 'f.tic'), 'unreadable renamed copy: tic left in place');
        like(log_text(), qr/\[ERROR\] cannot check f\.zip\.1/, 'unreadable renamed copy: error logged');

        # Running again may help with the unreadable file, so 2 wins.
        {
            local $ENV{LC_ALL} = 'C';
            setup();
            chmod 0, put($in, 'f.zip', 'x');
            put($in, 'f.tic', tic_text('File f.zip', 'Lfile ' . encode('cp866', 'Тест.zip'), 'Crc ' . crc('x')), 10);
            is(run_ticmambo(WaitForFileDays => 3, DeleteOrphanTics => 'Yes'), 2,
                'unreadable file and a name that cannot be looked for: exit code');
            ok(has($in, 'f.tic'), 'unreadable file and a name that cannot be looked for: tic left in place');
        }

        setup();
        chmod 0, put($in, 'f.zip', 'x');
        put($in, 'f.zip.1', 'x');
        put($in, 'f.tic', std_tic('f.zip', 'x'));
        is(run_ticmambo(), 0, 'unreadable file, readable copy matches: exit code');
        ok(has($dest, 'f.zip') && has($dest, 'f.tic'), 'readable copy moved');
    };
}

subtest 'tic or file gone before it is stat()ed' => sub {
    # As if moved away earlier in the same run: not there, not an error.
    my $sub = 'sub { if ($_[0] =~ /%s\z/) { $! = 2; return } CORE::lstat($_[0]) }';
    setup();
    put($in, 'f.zip', 'x');
    put($in, 'f.tic', std_tic('f.zip', 'x'));
    is(run_ticmambo(_preload => sprintf("package Fake; *main::lstat = $sub; package main", 'f\\.tic')),
        0, 'tic: exit code');
    like(log_text(), qr/\[DEBUG\] f\.tic is not a regular file, skipping/, 'tic: skipped');

    setup();
    put($in, 'f.zip', 'x');
    put($in, 'f.tic', std_tic('f.zip', 'x'), 10);
    is(run_ticmambo(WaitForFileDays => 3,
        _preload => sprintf("package Fake; *main::lstat = $sub; package main", '\\.zip')), 0, 'file: exit code');
    ok(has($dest, 'f.tic') && has($in, 'f.zip'), 'file: not there, tic is an orphan');
};

subtest 'file cannot be stat()ed' => sub {
    # The tic is stat()ed normally, the file is not. The override is
    # imported into main only, as for opendir.
    my $sub = 'sub { if ($_[0] =~ /\.zip\z/) { $! = 5; return } CORE::lstat($_[0]) }';
    for my $delete (qw(Yes No)) {
        setup();
        put($in, 'f.zip', 'x');
        put($in, 'f.tic', std_tic('f.zip', 'x'), 10);
        is(run_ticmambo(WaitForFileDays => 3, DeleteOrphanTics => $delete,
            _preload => "package Fake; *main::lstat = $sub; package main"), 2, "DeleteOrphanTics $delete: exit code");
        ok(has($in, 'f.tic') && has($in, 'f.zip'), "DeleteOrphanTics $delete: old tic not taken for an orphan");
        like(log_text(), qr/\[ERROR\] cannot check f\.zip: cannot stat/, "DeleteOrphanTics $delete: error logged");
    }
};

subtest 'read errors' => sub {
    # Tics are read in one go, files in 64 KB chunks.
    my $sub = 'sub { if (%s) { $! = 5; return undef } CORE::read($_[0], $_[1], $_[2]) }';
    my $tic_err  = sprintf $sub, '$_[2] != 65536';
    my $file_err = sprintf $sub, '$_[2] == 65536';

    setup();
    put($in, 'f.zip', 'x');
    put($in, 'f.tic', std_tic('f.zip', 'x'));
    is(run_ticmambo(_preload => "package Fake; *main::read = $tic_err; package main"), 2, 'tic: exit code');
    ok(has($in, 'f.tic') && has($in, 'f.zip'), 'tic: left in place');
    like(log_text(), qr/\[ERROR\] cannot read f\.tic/, 'tic: error logged');

    setup();
    put($in, 'f.zip', 'x');
    put($in, 'f.tic', std_tic('f.zip', 'x'), 10);
    is(run_ticmambo(WaitForFileDays => 3, DeleteOrphanTics => 'Yes',
        _preload => "package Fake; *main::read = $file_err; package main"), 2, 'file: exit code');
    ok(has($in, 'f.tic') && has($in, 'f.zip'), 'file: old tic not taken for an orphan');
    like(log_text(), qr/\[ERROR\] cannot check f\.zip: read error/, 'file: error logged');
};

subtest 'TouchFiles' => sub {
    setup();
    put($in, 'f.zip', 'x', 10);
    put($in, 'f.tic', std_tic('f.zip', 'x'), 10);
    run_ticmambo(TouchFiles => 'Yes');
    ok(time - (stat catfile($dest, 'f.zip'))[9] < 120, 'Yes: file mtime is now');

    setup();
    put($in, 'f.zip', 'x', 10);
    put($in, 'f.tic', std_tic('f.zip', 'x'), 10);
    run_ticmambo(TouchFiles => 'No');
    ok(time - (stat catfile($dest, 'f.zip'))[9] > 9 * $DAY, 'No: mtime preserved');

    setup();
    put($in, 'f.zip', 'x');
    put($in, 'f.tic', std_tic('f.zip', 'x'));
    is(run_ticmambo(TouchFiles => 'Yes', _preload => 'package Fake; *main::utime = sub { $! = 1; 0 }; package main'),
        0, 'cannot touch: exit code');
    ok(has($dest, 'f.zip') && has($dest, 'f.tic'), 'cannot touch: pair moved anyway');
    like(log_text(), qr/\[WARN \] cannot touch f\.zip/, 'cannot touch: logged');
};

subtest 'AddFullname' => sub {
    my $c = 'long';
    my $lfile = encode('cp866', 'Длинное имя.zip');
    my $tic = tic_text('Area TEST', 'File DLINNO~1.ZIP', "Lfile $lfile", 'Crc ' . crc($c), 'Seenby 2:5020/1');
    my $want = tic_text('Area TEST', 'File DLINNO~1.ZIP', "Lfile $lfile", "Fullname $lfile",
        'Crc ' . crc($c), 'Seenby 2:5020/1');

    setup();
    put($in, 'Длинное имя.zip', $c);
    put($in, 'f.tic', $tic, 10);
    run_ticmambo(AddFullname => 'Yes');
    is(slurp(catfile($dest, 'f.tic')), $want, 'Fullname added after Lfile, the rest intact');
    ok(time - (stat catfile($dest, 'f.tic'))[9] > 9 * $DAY, 'tic mtime preserved');
    ok(!has($dest, 'f.tic.tmp'), 'no temporary file left');
    like(log_text(), qr/f\.tic: added Fullname/, 'logged');

    setup();
    put($in, 'Длинное имя.zip', $c);
    put($in, 'f.tic', $tic);
    run_ticmambo(AddFullname => 'No');
    is(slurp(catfile($dest, 'f.tic')), $tic, 'No: tic unchanged');

    setup();
    put($in, 'f.zip', $c);
    put($in, 'f.tic', "File F.ZIP\nCrc " . crc($c) . "\rLfile f.zip");
    run_ticmambo(AddFullname => 'Yes');
    is(slurp(catfile($dest, 'f.tic')), tic_text('File F.ZIP', 'Crc ' . crc($c), 'Lfile f.zip', 'Fullname f.zip'),
        'LF and CR line endings, last line without EOL: written with CR LF');

    for my $t ([has_fullname => tic_text('File f.zip', 'Lfile f.zip', 'Fullname f.zip', 'Crc ' . crc($c))],
               [no_lfile => tic_text('File f.zip', 'Fullname f.zip', 'Crc ' . crc($c))],
               [no_long => tic_text('File f.zip', 'Crc ' . crc($c))]) {
        setup();
        put($in, 'f.zip', $c);
        put($in, 'f.tic', $t->[1]);
        run_ticmambo(AddFullname => 'Yes');
        is(slurp(catfile($dest, 'f.tic')), $t->[1], "$t->[0]: tic unchanged");
    }

    for my $t (['empty Fullname before Lfile', ['File F.ZIP', 'Fullname', 'Lfile f.zip'],
                ['File F.ZIP', 'Fullname f.zip', 'Lfile f.zip']],
               ['empty Fullname after Lfile', ['File F.ZIP', 'Lfile f.zip', "Fullname \t"],
                ['File F.ZIP', 'Lfile f.zip', "Fullname \tf.zip"]]) {
        setup();
        put($in, 'f.zip', $c);
        put($in, 'f.tic', tic_text(@{$t->[1]}, 'Crc ' . crc($c)));
        run_ticmambo(AddFullname => 'Yes');
        is(slurp(catfile($dest, 'f.tic')), tic_text(@{$t->[2]}, 'Crc ' . crc($c)), "$t->[0]: filled in");
    }

    setup();
    my $bom = "\xEF\xBB\xBF" . tic_text('Lfile f.zip', 'Crc ' . crc($c));
    put($in, 'f.zip', $c);
    put($in, 'f.tic', $bom);
    run_ticmambo(AddFullname => 'Yes', TicCharset => 'UTF-8');
    is(slurp(catfile($dest, 'f.tic')), tic_text('Lfile f.zip', 'Fullname f.zip', 'Crc ' . crc($c)),
        'BOM before Lfile: Fullname added, BOM dropped');

    setup();
    put($in, 'f.tic', tic_text('File f.zip', 'Lfile f.zip', 'Crc ' . crc($c)), 10);
    run_ticmambo(AddFullname => 'Yes', WaitForFileDays => 3);
    is(slurp(catfile($dest, 'f.tic')), tic_text('File f.zip', 'Lfile f.zip', 'Crc ' . crc($c)),
        'orphan tic unchanged');

    setup();
    put($in, 'Длинное имя.zip', $c);
    put($in, 'f.tic', $tic);
    mkdir catfile($dest, 'f.tic.tmp') or die $!;
    is(run_ticmambo(AddFullname => 'Yes'), 0, 'cannot write: exit code');
    is(slurp(catfile($dest, 'f.tic')), $tic, 'cannot write: tic moved unchanged');
    ok(has($dest, 'Длинное имя.zip'), 'cannot write: file moved anyway');
    like(log_text(), qr/f\.tic: cannot edit \(added Fullname\)/, 'cannot write: logged');
};

subtest 'FixShortName: cases that leave the tic alone' => sub {
    my $c = 'long';
    my $tic = tic_text('File WRONG~9.ZIP', 'Lfile Long File Name.zip', 'Crc ' . crc($c));

    setup();
    put($in, 'Long File Name.zip', $c);
    put($in, 'f.tic', $tic);
    run_ticmambo(FixShortName => 'No');
    is(slurp(catfile($dest, 'f.tic')), $tic, 'No: tic unchanged');

    setup();
    put($in, 'f.zip', $c);
    put($in, 'f.tic', tic_text('File F.ZIP', 'Lfile f.zip', 'Crc ' . crc($c)));
    run_ticmambo(FixShortName => 'Yes');
    is(slurp(catfile($dest, 'f.tic')), tic_text('File F.ZIP', 'Lfile f.zip', 'Crc ' . crc($c)),
        'long name equal to File: tic unchanged');

    unless ($IS_WIN) {
        setup();
        put($in, 'Long File Name.zip', $c);
        put($in, 'f.tic', $tic);
        run_ticmambo(FixShortName => 'Yes');
        is(slurp(catfile($dest, 'f.tic')), $tic, 'not Windows: ignored');
    }
};

SKIP: {
    skip 'Win32 only', 2 unless $IS_WIN;

    # Needs 8.3 names on the volume of the temporary directory: without them
    # FixShortName cannot work, and this test fails.
    subtest 'FixShortName' => sub {
        my $c = 'long';
        setup();
        put($in, 'Long File Name.zip', $c);
        put($in, 'f.tic', tic_text('File WRONG~9.ZIP', 'Lfile Long File Name.zip', 'Crc ' . crc($c)));
        run_ticmambo(FixShortName => 'Yes');
        ok(has($dest, 'Long File Name.zip'), 'file moved');
        my $short = Win32::GetShortPathName(catfile($dest, fsn('Long File Name.zip')));
        $short = (File::Spec->splitpath($short))[2] if defined $short;
        like($short, qr/^[^.]{1,8}\.[^.]{1,3}\z/, 'file has an 8.3 short name');
        is(slurp(catfile($dest, 'f.tic')), tic_text("File $short", 'Lfile Long File Name.zip', 'Crc ' . crc($c)),
            'File replaced with the short name');
    };

    subtest 'FixShortName: no short name (simulated)' => sub {
        my $c = 'long';
        my $tic = tic_text('File WRONG~9.ZIP', 'Lfile Long File Name.zip', 'Crc ' . crc($c));
        for my $t (['8.3 names disabled', 'sub { $_[0] }', qr/has no short name, File left as is/],
                   ['GetShortPathName fails', 'sub { undef }', qr/cannot get the short name/]) {
            my ($label, $sub, $warning) = @$t;
            setup();
            put($in, 'Long File Name.zip', $c);
            put($in, 'f.tic', $tic);
            run_ticmambo(FixShortName => 'Yes',
                _preload => "require Win32; no warnings; *Win32::GetShortPathName = $sub");
            ok(has($dest, 'Long File Name.zip'), "$label: file moved");
            is(slurp(catfile($dest, 'f.tic')), $tic, "$label: tic unchanged");
            like(log_text(), $warning, "$label: warning logged");
        }
    };
}

subtest 'tic referring to a tic is corrupt' => sub {
    # The file found as a renamed copy would be moved under the tic's own
    # name and then overwritten by the tic.
    setup();
    put($in, 'b.tic.1', 'x');
    put($in, 'b.tic', std_tic('b.tic', 'x'));
    put($in, 'c.tic', tic_text('File c.zip', 'Lfile Other.TIC', 'Crc ' . crc('x')));
    is(run_ticmambo(), 0, 'exit code');
    ok(has($corrupt, 'b.tic') && has($in, 'b.tic.1'), 'File: corrupt, file left alone');
    ok(has($corrupt, 'c.tic'), 'Lfile in another case: corrupt');

    setup();
    put($in, 'f.zip', 'x');
    put($in, 'd.tic', tic_text('File f.zip', 'Lfile f.zip', 'Fullname evil.tic', 'Crc ' . crc('x')));
    run_ticmambo();
    ok(has($corrupt, 'd.tic') && has($in, 'f.zip'), 'Fullname checked even with Lfile');
};

SKIP: {
    skip 'Win32 only', 1 unless $IS_WIN;
    subtest 'hidden files and tics' => sub {
        require Win32::File;
        my $hide = sub { Win32::File::SetAttributes($_[0], Win32::File::HIDDEN()) or die; $_[0] };
        my $hidden = sub {
            Win32::File::GetAttributes($_[0], my $attr) or die;
            return $attr & Win32::File::HIDDEN();
        };

        setup();
        $hide->(put($in, 'empty.tic', '', 1));
        $hide->(put($in, 'f.tic', std_tic('f.zip', 'x'), 1));
        put($in, 'f.zip', 'x');
        run_ticmambo(WaitForHiddenTicDays => 7, WaitForFileDays => 0);
        ok(has($in, 'empty.tic') && has($in, 'f.tic') && has($in, 'f.zip'), 'young hidden tics skipped');

        run_ticmambo(WaitForHiddenTicDays => 0, WaitForFileDays => 0);
        ok(has($dest, 'f.tic') && has($dest, 'f.zip'), '0: hidden tic processed at once');
        ok(!$hidden->(catfile($dest, 'f.tic')), 'attribute cleared on tic in DestPath');
        ok(has($corrupt, 'empty.tic'), 'hidden corrupt tic moved to CorruptTicPath');
        ok($hidden->(catfile($corrupt, 'empty.tic')), 'attribute kept outside DestPath');

        setup();
        $hide->(put($in, 'f.tic', std_tic('f.zip', 'x'), 8));
        $hide->(put($in, 'g.tic', std_tic('none.zip', 'x'), 8));
        put($in, 'f.zip', 'x');
        run_ticmambo(WaitForHiddenTicDays => 7, WaitForFileDays => 3);
        ok(has($dest, 'f.tic') && has($dest, 'f.zip'), 'old hidden tic processed');
        ok(has($dest, 'g.tic') && !$hidden->(catfile($dest, 'g.tic')), 'orphan moved to DestPath unhidden');

        setup();
        $hide->(put($in, 'f.zip', 'x'));
        $hide->(put($in, 'g.zip', 'other'));
        put($in, 'f.tic', std_tic('f.zip', 'x'));
        put($in, 'g.tic', std_tic('g.zip', 'x'));
        run_ticmambo(WaitForFileDays => 3);
        ok(has($dest, 'f.zip') && !$hidden->(catfile($dest, 'f.zip')), 'hidden file processed, unhidden');
        ok(has($in, 'g.zip') && $hidden->(catfile($in, 'g.zip')), 'non-matching hidden file untouched');
    };
}

subtest 'UseCreationTime' => sub {
    # The tic is created now but its mtime is 10 days old.
    setup();
    my $probe = put($root, 'probe', '');
    # The same check as in the script.
    my $birth = $IS_WIN || $^O eq 'linux' && eval { require 'syscall.ph'; SYS_statx() }
        && `stat -c %W '$probe' 2>/dev/null` =~ /^[1-9]/;
    for my $use (qw(Yes No)) {
        setup();
        put($in, 'f.tic', std_tic('none.zip', 'x'), 10);
        run_ticmambo(UseCreationTime => $use, WaitForFileDays => 3);
        if ($use eq 'Yes' && $birth) {
            ok(has($in, 'f.tic'), 'Yes: age taken from creation time');
        }
        else {
            ok(has($dest, 'f.tic'), "$use: age taken from modification time");
        }
    }
};

SKIP: {
    skip 'Win32 only', 1 unless $IS_WIN;
    subtest 'file open for writing is not moved' => sub {
        setup();
        my $path = put($in, 'f.zip', 'x');
        put($in, 'f.tic', std_tic('f.zip', 'x'));
        open my $fh, '>>', $path or die "$path: $!";
        run_ticmambo();
        close $fh;
        ok(has($in, 'f.zip') && has($in, 'f.tic'), 'file and tic left in place');
        is(slurp($path), 'x', 'content intact');
        ok(!has($dest, 'f.zip') && !has($dest, 'f.tic'), 'nothing in DestPath');
        like(log_text(), qr/cannot move/, 'error logged');

        run_ticmambo();
        ok(has($dest, 'f.zip') && has($dest, 'f.tic'), 'moved on the next run');
    };
}

subtest 'config line endings' => sub {
    for my $eol ("\r\n", "\n", "\r") {
        setup();
        put($in, 'f.zip', 'x');
        put($in, 'f.tic', std_tic('f.zip', 'x'));
        my $name = join '', map { sprintf '%02X', ord } split //, $eol;
        my $text = "\xEF\xBB\xBF; comment$eol${eol}InboundPath $in${eol}DestPath $dest$eol"
            . "CorruptTicAction Keep${eol}LogFile $log$eol";
        my $cfg = put($root, 'eol.cfg', $text);
        is(system($^X, $SCRIPT, $cfg) >> 8, 0, "$name: config accepted");
        ok(has($dest, 'f.zip'), "$name: config applied");

        put($root, 'eol.cfg', $text . "TouchFiles Maybe$eol");
        my $err = catfile($root, 'err.txt');
        system(qq("$^X" "$SCRIPT" "$cfg" 2>"$err"));
        like(slurp($err), qr/line 7: invalid value 'Maybe'/, "$name: error line number");
    }
};

subtest 'non-ASCII paths in a UTF-8 config' => sub {
    setup();
    my $in2 = catfile($root, fsn('входящие'));
    mkdir $in2 or die $!;
    put($in2, 'f.zip', 'x');
    put($in2, 'f.tic', std_tic('f.zip', 'x'));
    my ($r, $d, $l) = map { decode(locale_fs => $_) } $root, $dest, $log;
    my $cfg = put($root, 'utf8.cfg', encode('UTF-8', "InboundPath $r/входящие\r\nDestPath $d\r\n"
        . "CorruptTicAction Keep\r\nLogFile $l\r\n"));
    is(system($^X, $SCRIPT, $cfg) >> 8, 0, 'config accepted');
    ok(has($dest, 'f.zip') && has($dest, 'f.tic'), 'InboundPath found');
};

subtest 'config errors' => sub {
    setup();
    is(run_ticmambo(InboundPath => undef), 1, 'missing InboundPath');
    is(run_ticmambo(DestPath => undef), 1, 'missing DestPath');
    is(run_ticmambo(DestPath => catfile($root, 'nope')), 1, 'nonexistent DestPath');
    is(run_ticmambo(CorruptTicPath => undef), 1, 'Move without CorruptTicPath');
    is(run_ticmambo(CorruptTicPath => undef, CorruptTicAction => 'Keep'), 0, 'Keep without CorruptTicPath');
    is(run_ticmambo(CorruptTicAction => 'Explode'), 1, 'bad CorruptTicAction');
    is(run_ticmambo(TouchFiles => 'Maybe'), 1, 'bad boolean');
    is(run_ticmambo(WaitForFileDays => '-1'), 1, 'bad number');
    is(run_ticmambo(TicCharset => 'no-such-charset'), 1, 'bad charset');
    is(run_ticmambo(LogLevel => 'chatty'), 1, 'bad log level');
    is(run_ticmambo(NoSuchKeyword => 1), 1, 'unknown keyword');
    is(run_ticmambo(DestPath => $in), 1, 'DestPath is InboundPath');
    is(run_ticmambo(DestPath => "$in/../in"), 1, 'DestPath is InboundPath, other spelling');
    is(run_ticmambo(CorruptTicPath => $in), 1, 'CorruptTicPath is InboundPath');
    mkdir catfile($root, 'IN');
    is(run_ticmambo(DestPath => catfile($root, 'IN')), 1, 'DestPath is InboundPath but for case');
    is(system($^X, $SCRIPT, catfile($root, 'missing.cfg')) >> 8, 1, 'missing config file');
    is(run_ticmambo(LogLevel => undef, touchfiles => "yes", LOGLEVEL => "INFO"), 0, 'keywords and values are case insensitive');
};

done_testing();
