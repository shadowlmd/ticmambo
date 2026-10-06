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

binmode Test::More->builder->$_, ':encoding(console_out)' for qw(output failure_output todo_output);

my $SCRIPT = catfile($FindBin::Bin, '..', 'ticmambo.pl');
my $IS_WIN = $^O eq 'MSWin32';
my $DAY    = 86400;

my ($root, $in, $dest, $corrupt, $log);

# Text file name to file system bytes.
sub fsn { encode(locale_fs => $_[0]) }

sub setup {
    $root   = tempdir(CLEANUP => 1);
    $in     = catfile($root, 'in');
    $dest   = catfile($root, 'dest');
    $corrupt = catfile($root, 'corrupt');
    $log    = catfile($root, 'ticmambo.log');
    mkdir $_ or die "mkdir $_: $!" for $in, $dest, $corrupt;
}

# Runs ticmambo with the base config plus overrides, returns the exit code.
sub run_ticmambo {
    my (%opt) = @_;
    my %cfg = (
        TicPath         => $in,
        DestPath        => $dest,
        CorruptTicPath   => $corrupt,
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
    system($^X, $SCRIPT, $cfg_file);
    return $? >> 8;
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

sub dump_log_on_fail {
    diag(log_text()) unless Test::More->builder->is_passing;
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
    dump_log_on_fail();
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
    run_ticmambo();
    ok(has($dest, "$_.zip") && has($dest, "$_.tic"), "$_ moved") for qw(lc nosize zeros empty);
    dump_log_on_fail();
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
    ['no Crc',         sub { tic_text('File f.zip', 'Size 4') }],
    ['short Crc',      sub { tic_text('File f.zip', 'Crc ' . substr(crc('abcd'), 1)) }],
    ['long Crc',       sub { tic_text('File f.zip', 'Crc 0' . crc('abcd')) }],
    ['non-hex Crc',    sub { tic_text('File f.zip', 'Crc XYZXYZXY') }],
    ['Crc with junk',  sub { tic_text('File f.zip', 'Crc ' . crc('abcd') . ' junk') }],
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
        dump_log_on_fail();
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

    setup();
    put($in, 'file.zip.1', 'wrong 1');
    put($in, 'file.zip.2', $c);
    put($in, 'file.zip.3', 'wrong 3');
    put($in, 'f.tic', std_tic('file.zip', $c));
    run_ticmambo();
    is(slurp(catfile($dest, 'file.zip')), $c, 'only copies, the matching one moved');
    ok(has($in, 'file.zip.1') && has($in, 'file.zip.3'), 'other copies untouched');

    setup();
    put($in, 'README.1', $c);
    put($in, 'Long Name.tar.gz.1', $c);
    put($in, 'a.tic', std_tic('README', $c));
    put($in, 'b.tic', tic_text('File LONGNA~1.GZ', 'Lfile Long Name.tar.gz', 'Crc ' . crc($c)));
    run_ticmambo();
    ok(has($dest, 'README'), 'name without extension');
    ok(has($dest, 'Long Name.tar.gz'), 'Lfile copy');

    setup();
    put($in, $_, $c) for 'file.zip1', 'xfile.zip.1', 'file.zip.', 'file.zi', 'file.zipx', 'file.zi_', 'file.zi0.1';
    put($in, 'f.tic', std_tic('file.zip', $c));
    run_ticmambo(WaitForFileDays => 3);
    ok(has($in, 'f.tic'), 'similar names that are not copies are ignored');
    ok(!has($dest, 'file.zip'), 'nothing moved');

    setup();
    put($in, 'FILE.ZIP.1', $c);
    put($in, 'f.tic', std_tic('file.zip', $c));
    run_ticmambo(ForceCaseInsensitive => 'No', WaitForFileDays => 3);
    ok(has($in, 'FILE.ZIP.1'), 'No: copy in other case ignored') unless $IS_WIN;
    run_ticmambo(ForceCaseInsensitive => 'Yes');
    ok(has($dest, 'file.zip'), 'Yes: copy in other case moved under tic name');

    setup();
    put($in, 'file.zip.1', $c);
    put($in, 'f.tic', std_tic('file.zip', $c));
    put($dest, 'file.zip', 'previous');
    run_ticmambo();
    ok(has($in, 'file.zip.1') && has($in, 'f.tic'), 'name taken in DestPath: skipped');
    is(slurp(catfile($dest, 'file.zip')), 'previous', 'DestPath file intact');
    dump_log_on_fail();
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
        dump_log_on_fail();
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
    ok(has($corrupt, $_), "$_ quarantined") for qw(nofile.tic empty.tic blank.tic emptyval.tic);
    dump_log_on_fail();
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
        is(scalar @left, 20, 'every junk tic is either waiting or quarantined');
        dump_log_on_fail();
    };
}

subtest 'Lfile, Fullname and File' => sub {
    setup();
    put($in, 'Long File Name.zip', 'long');
    put($in, 'LONGFI~1.ZIP', 'short');
    put($in, '1.tic', tic_text('File LONGFI~1.ZIP', 'Lfile Long File Name.zip', 'Crc ' . crc('long')));
    run_ticmambo();
    ok(has($dest, 'Long File Name.zip'), 'Lfile preferred');
    ok(has($in, 'LONGFI~1.ZIP'), 'short name untouched');

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
    dump_log_on_fail();
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
    dump_log_on_fail();
};

subtest 'ForceCaseInsensitive' => sub {
    SKIP: {
        skip 'file system is case insensitive', 2 if $IS_WIN;
        setup();
        put($in, 'file.zip', 'x');
        put($in, 'f.tic', tic_text('File FILE.ZIP', 'Crc ' . crc('x')));
        run_ticmambo(ForceCaseInsensitive => 'No', WaitForFileDays => 3);
        ok(has($in, 'f.tic') && has($in, 'file.zip'), 'No: different case is not found');

        put($in, 'f.tic', tic_text('File file.zip', 'Crc ' . crc('x')));
        put($in, 'FILE.ZIP', 'x');
        run_ticmambo(ForceCaseInsensitive => 'Yes');
        ok(has($dest, 'file.zip') && has($in, 'FILE.ZIP'), 'Yes: exact name is checked first');
    }
    setup();
    put($in, 'file.zip', 'x');
    put($in, 'f.tic', tic_text('File FILE.ZIP', 'Crc ' . crc('x')));
    run_ticmambo(ForceCaseInsensitive => 'Yes');
    ok(has($dest, 'file.zip'), 'Yes: found and moved under its own name');
    dump_log_on_fail();
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
    run_ticmambo(ForceCaseInsensitive => 'Yes');
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
    dump_log_on_fail();
};

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
                ok(has($corrupt, $t) && !has($in, $t), "$t quarantined");
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
        dump_log_on_fail();
    };
}

subtest 'invalid Size makes the tic corrupt' => sub {
    setup();
    put($in, 'f.zip', 'abcd');
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
    put($in, $_, tic_text('File f.zip', $tics{$_}, "Crc $crc")) for keys %tics;
    run_ticmambo();
    ok(has($corrupt, $_), "$tics{$_}: quarantined") for sort keys %tics;
    ok(has($in, 'f.zip'), 'file untouched');
    dump_log_on_fail();
};

subtest 'NUL bytes and oversized tics are corrupt' => sub {
    setup();
    put($in, 'f.zip', 'x');
    put($in, 'nul.tic', "File f.zip\r\nCrc " . crc('x') . "\r\n\0");
    put($in, 'big.tic', std_tic('f.zip', 'x') . ('Ldesc ' . ('x' x 70) . "\r\n") x 1000);
    put($in, 'limit.tic', std_tic('g.zip', 'x'));
    run_ticmambo(MaxTicSize => 2000);
    ok(has($corrupt, 'nul.tic'), 'tic with NUL quarantined');
    ok(has($corrupt, 'big.tic'), 'oversized tic quarantined');
    ok(has($in, 'f.zip'), 'file untouched');
    ok(has($in, 'limit.tic'), 'small tic processed normally');
    dump_log_on_fail();
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
        ok(has($corrupt, 'rnd.tic'), '1 MB random tic quarantined');
        ok(has($corrupt, 'rnd2.tic'), 'small binary tic quarantined');
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
        ok(has($corrupt, 'huge.tic'), 'quarantined');
    };
}

SKIP: {
    skip 'no symlinks/fifos on Win32', 1 if $IS_WIN;
    subtest 'special files' => sub {
        setup();
        require POSIX;
        my $victim = put($root, 'victim', 'secret');
        symlink $victim, catfile($in, 'link.zip') or die $!;
        put($in, 'link.tic', std_tic('link.zip', 'secret'));
        symlink '/dev/urandom', catfile($in, 'urandom.tic') or die $!;
        symlink $victim, catfile($in, 'victim.tic') or die $!;
        POSIX::mkfifo(catfile($in, 'fifo.tic'), 0600) or die $!;
        POSIX::mkfifo(catfile($in, 'fifo.zip'), 0600) or die $!;
        put($in, 'fifo-ref.tic', std_tic('fifo.zip', ''));
        mkdir catfile($in, 'dir.tic');
        mkdir catfile($in, 'dir.zip');
        put($in, 'dir-ref.tic', std_tic('dir.zip', ''));

        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 30;
        my $rc = run_ticmambo(WaitForFileDays => 3);
        alarm 0;
        is($rc, 0, 'finished without hanging');
        is(slurp($victim), 'secret', 'victim untouched');
        ok(-l catfile($in, 'link.zip') && has($in, 'link.tic'), 'symlinked data file not used');
        ok(-l catfile($in, 'urandom.tic') && -l catfile($in, 'victim.tic'), 'symlinked tics ignored');
        ok(-p catfile($in, 'fifo.tic'), 'fifo tic ignored');
        ok(has($in, 'fifo-ref.tic'), 'fifo data file not used');
        ok(-d catfile($in, 'dir.tic') && has($in, 'dir-ref.tic'), 'directories ignored');
        dump_log_on_fail();
    };
}

subtest 'existing files in DestPath' => sub {
    setup();
    put($in, 'f.zip', 'new');
    put($in, 'f.tic', std_tic('f.zip', 'new'));
    put($dest, 'f.zip', 'old');
    run_ticmambo();
    ok(has($in, 'f.zip') && has($in, 'f.tic'), 'file exists in dest: pair skipped');
    is(slurp(catfile($dest, 'f.zip')), 'old', 'dest file not overwritten');

    setup();
    put($in, 'f.zip', 'new');
    put($in, 'f.tic', std_tic('f.zip', 'new'));
    put($dest, 'f.tic', 'old tic');
    run_ticmambo();
    ok(has($in, 'f.zip') && has($in, 'f.tic'), 'tic exists in dest: pair skipped');

    setup();
    put($in, 'f.zip', 'new');
    put($in, 'f.tic', std_tic('f.zip', 'new'));
    put($dest, 'f.zip', 'old');
    put($dest, 'f.tic', 'old tic');
    run_ticmambo(OverwriteExisting => 'Yes');
    is(slurp(catfile($dest, 'f.zip')), 'new', 'OverwriteExisting: file replaced');
    is(slurp(catfile($dest, 'f.tic')), std_tic('f.zip', 'new'), 'OverwriteExisting: tic replaced');

    setup();
    put($in, 'evil.tic', tic_text('File ../x'));
    put($corrupt, 'evil.tic', 'previous');
    run_ticmambo();
    ok(has($in, 'evil.tic'), 'corrupt tic kept when quarantine already has one');
    dump_log_on_fail();
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
};

subtest 'separate FilesPath' => sub {
    setup();
    my $files = catfile($root, 'files');
    mkdir $files;
    put($files, 'f.zip', 'x');
    put($in, 'f.zip', 'wrong');
    put($in, 'f.tic', std_tic('f.zip', 'x'));
    run_ticmambo(FilesPath => $files);
    ok(has($dest, 'f.zip') && !has($files, 'f.zip'), 'file taken from FilesPath');
    is(slurp(catfile($dest, 'f.zip')), 'x', 'right file');
};

subtest 'tic referring to another tic' => sub {
    setup();
    my $inner = std_tic('x.zip', 'x');
    put($in, 'inner.tic', $inner, 1);
    put($in, 'outer.tic', std_tic('inner.tic', $inner), 1);
    run_ticmambo(WaitForFileDays => 3);
    ok(has($dest, 'inner.tic') && has($dest, 'outer.tic'), 'moved like any file');
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
        ok(has($corrupt, 'empty.tic'), 'hidden corrupt tic quarantined');
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
        dump_log_on_fail();
    };
}

subtest 'UseCreationTime' => sub {
    # The tic is created now but its mtime is 10 days old.
    my $birth = $IS_WIN || $^O eq 'linux' && eval { require 'syscall.ph'; 1 };
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
        dump_log_on_fail();
    };
}

subtest 'config line endings' => sub {
    for my $eol ("\r\n", "\n", "\r") {
        setup();
        put($in, 'f.zip', 'x');
        put($in, 'f.tic', std_tic('f.zip', 'x'));
        my $name = join '', map { sprintf '%02X', ord } split //, $eol;
        my $text = "\xEF\xBB\xBF; comment$eol${eol}TicPath $in${eol}DestPath $dest$eol"
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

subtest 'config errors' => sub {
    setup();
    isnt(run_ticmambo(TicPath => undef), 0, 'missing TicPath');
    isnt(run_ticmambo(DestPath => undef), 0, 'missing DestPath');
    isnt(run_ticmambo(DestPath => catfile($root, 'nope')), 0, 'nonexistent DestPath');
    isnt(run_ticmambo(CorruptTicPath => undef), 0, 'Move without CorruptTicPath');
    is(run_ticmambo(CorruptTicPath => undef, CorruptTicAction => 'Keep'), 0, 'Keep without CorruptTicPath');
    isnt(run_ticmambo(CorruptTicAction => 'Explode'), 0, 'bad CorruptTicAction');
    isnt(run_ticmambo(TouchFiles => 'Maybe'), 0, 'bad boolean');
    isnt(run_ticmambo(WaitForFileDays => '-1'), 0, 'bad number');
    isnt(run_ticmambo(TicCharset => 'no-such-charset'), 0, 'bad charset');
    isnt(run_ticmambo(LogLevel => 'chatty'), 0, 'bad log level');
    isnt(run_ticmambo(NoSuchKeyword => 1), 0, 'unknown keyword');
    isnt(system($^X, $SCRIPT, catfile($root, 'missing.cfg')) >> 8, 0, 'missing config file');
    is(run_ticmambo(LogLevel => undef, touchfiles => "yes", LOGLEVEL => "INFO"), 0, 'keywords and values are case insensitive');
};

done_testing();
