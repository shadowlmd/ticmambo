# TicMambo

> Mambo is a title given to the most respected and knowledgeable women in
> the Voodoo religion.
>
> — Rue Allyn, *The Creole Duchess*

TicMambo is a pre-processor for Fidonet file echo inbound. It checks each
incoming TIC file ([FTS-5006](http://ftsc.org/docs/fts-5006.001)) against
the file it describes. Only pairs that really match go on to the file echo
processor.

## Why

Sometimes several tics arrive for the same file. Many file echo processors
check the file against the first tic they find, and if the size or CRC
doesn't match, the tic is rejected as bad: renamed or moved to a bad tics
directory. Often the file goes with it, and the remaining tics, including
the one that matches, end up rejected as well.

TicMambo looks at every tic on its own and moves a file only together with
a tic that matches it. Tics that don't match yet wait for their file, so
the file echo processor only gets pairs that are already known to be good.

## How it works

TicMambo reads the tic directory once per run and handles every `*.tic`
file found there:

1. **Hidden tic** (Windows). A tic with the hidden attribute may still be
   being received, so it is skipped for `WaitForHiddenTicDays` days.
2. **Corrupt tic.** The tic is larger than `MaxTicSize`, contains NUL bytes,
   has no `File`/`Lfile`, has a `Size` that is not a decimal number, or
   names a file with a path, a drive letter, control characters, `.`, `..`
   or a device name such as `CON` or `NUL`. Such a tic is moved to
   `CorruptTicPath`, deleted, or left in place, depending on
   `CorruptTicAction`.
3. **Looking for the file.** The name is taken from `Lfile` (or `Fullname`),
   then from `File`, and converted from `TicCharset` to the file system
   encoding. Copies that the mailer renamed because a file with the same
   name already existed are checked too: `file.zip.1` (binkd "postfix"
   style) and `file.zi0` (binkd "extension" style). Names are compared
   with or without regard to case as `FileNamesCaseSensitive` says (by
   default without on Windows and with elsewhere), on any file system.
4. **Match.** A file matches if its CRC-32 equals `Crc` and, when the tic has
   a `Size`, its size equals `Size`. The first matching file is moved to
   `DestPath` together with the tic, and a renamed copy gets the name from
   the tic. If a file or tic with the same name is already in `DestPath`,
   the pair is left for the next run (see `OverwriteExisting`).
5. **No match.** A tic without a matching file waits `WaitForFileDays` days,
   then it is moved to `DestPath` alone or deleted (see `DeleteOrphanTics`).
   Files that don't match are never touched.

Nothing in `DestPath` is left hidden: the hidden attribute is cleared on
every file and tic moved there. Tics are never modified.

The age of a tic is based on its creation time where it is available
(Windows; Linux via `statx(2)`), and on its modification time otherwise.

## Requirements

Perl 5.16 or later with the following modules:

- `Encode`, `Compress::Zlib`, `Cwd`, `File::Copy`, `File::Spec`, `POSIX`
  (part of standard Perl);
- `Encode::Locale`;
- `Win32::File` (Windows only).

Strawberry Perl includes all of them. On Linux, `Encode::Locale` is usually
available as a distribution package (for example `libencode-locale-perl` on
Debian and Ubuntu).

## Usage

```
perl ticmambo.pl [config]
```

Without an argument, `ticmambo.cfg` next to the script is used. Copy
[ticmambo.cfg.sample](ticmambo.cfg.sample), adjust the paths, and set
`DestPath` as the inbound in your file echo processor's config.

Run TicMambo right before the file echo processor, for example from the
same script or scheduler job. Do not start it from a mailer that can run
several sessions at once: TicMambo has no locking, and two copies running
at the same time get in each other's way.

The exit code is 0 after a normal run, and 1 if the config is invalid or
the log file or the tic directory cannot be opened. Problems with
individual tics and files are logged and do not stop the run.

## Configuration

All keywords are described in [ticmambo.cfg.sample](ticmambo.cfg.sample).
Only `TicPath`, `DestPath` and, with the default `CorruptTicAction Move`,
`CorruptTicPath` are required. `DestPath` and `CorruptTicPath` must be
different from `TicPath` and `FilesPath`.

The config is read as UTF-8 or, if it is not valid UTF-8, in the system
encoding (the ANSI code page on Windows).

## Logging

Messages go to `LogFile` (UTF-8) or, if it is not set, to stderr. `LogLevel`
selects how much is logged: `error`, `warn`, `info` (default) or `debug`.

## Tests

```
prove t
```

The tests run TicMambo on temporary directories. They cover matching and
non-matching files, renamed copies, malformed and malicious tics, character
sets, case insensitivity, and config errors. Tests that need Windows
(hidden attributes, open files) or Unix (symlinks, FIFOs, a sparse 2 GB tic)
are skipped on other systems.

## License

TicMambo is free software under the [WTFPL](http://www.wtfpl.net/), version 2.
See [COPYING](COPYING).
