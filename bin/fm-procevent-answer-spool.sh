#!/usr/bin/env bash
# Answer-spool adapter for the generic process-to-event runner: watch one local
# directory into which an outside process drops keyed captain answers and merge
# orders, and turn each dropped record into a durable capture.
#
# Usage:
#   fm-procevent-answer-spool.sh arm <spool-dir>
#   fm-procevent-answer-spool.sh classify <result-file>
#   fm-procevent-answer-spool.sh terminal <result-file>
#   fm-procevent-answer-spool.sh silent <result-file>
#   fm-procevent-answer-spool.sh answers <result-file>
#   fm-procevent-answer-spool.sh read <result-file>
#   fm-procevent-answer-spool.sh source-id <spool-dir>
#   fm-procevent-answer-spool.sh retire <spool-dir>
#   fm-procevent-answer-spool.sh poll <spool-dir>
#
# arm        Register the spool directory as a source, creating it at mode 0700
#            when absent. BIND BEFORE YOU ARM. `arm` deliberately does not bind
#            the keyed-answer intake, because binding is the caller decision and
#            the ORDER carries the safety: bind first and a captured answer can
#            never exist with nowhere to go, arm first and an answer dropped in
#            the gap is captured against an unbound source and feeds nothing.
#            The supported sequence is one line longer for that reason:
#              id=$(bin/fm-procevent-answer-spool.sh source-id <spool-dir>)
#              bin/fm-captain-hold.sh bind "$id"
#              bin/fm-procevent-answer-spool.sh arm <spool-dir>
#            `arm` prints a note when the source is still unbound. That note is
#            information, not a bind and not a refusal: an operator may arm a
#            spool that carries only merge orders, which feed no intake at all.
# poll       The registered listener command `arm` publishes, not a command to
#            run in a conversational turn. It blocks until at least one record
#            is claimable, claims a bounded batch, and prints one capture.
# answers    This adapter half of the generic keyed-answer contract in
#            bin/fm-procevent.sh. It prints the captured keyed-answer lines and
#            NOTHING else. MERGE ORDERS NEVER APPEAR HERE: a pull request
#            address is not an answer, and feeding one to the keyed-answer
#            intake would record it as the answer to a question nobody asked.
#            A merge order reaches a handler through `read`, and only there.
# read       A structured presentation of one capture: both record kinds, the
#            declared and presented counts, and an explicit completeness
#            verdict. Read-only over the capture; it claims nothing and changes
#            nothing.
# classify   Print the state a handler acts on: orders, answers, rejected,
#            empty, or unknown. Precedence is by how much handler action the
#            capture demands, so a capture carrying both kinds classifies
#            `orders` - the answers are already fed, the order is not. `read`
#            is always the complete view; classify is a routing hint.
# terminal   Exit 0 when the capture means this source will never produce
#            another result. See NOTHING ENDS A WATCHED DIRECTORY below.
# silent     Exit 0 when the capture is a routine no-op the runner should record
#            and never announce. See SILENCE IS POSITIVELY DETERMINED below.
#
# THIS ADAPTER DECIDES NOTHING. It transports; it does not translate and it does
# not judge. It never asks whether a captain call is still open, whether a merge
# may happen, or whether a key names anything. bin/fm-captain-hold.sh owns the
# first two of those and bin/fm-pr-merge.sh owns the third, and each of them
# re-verifies at handling time against live state rather than against these
# bytes. An adapter that grew such a judgment would be a second authority over
# an answer, which is exactly the duplication the one keyed-answer intake exists
# to prevent.
#
# THE RECORD FORMAT IS NOT THIS ADAPTER OWN. It is an already-shipped contract
# with a second writer outside this repository, so this file reads it and never
# redefines it. Two shapes, each one line, newline-terminated, with no header,
# timestamp, or provenance block:
#
#   <request-id>.keyed-answer-v1   ->   <task-id>\t<answer>\t<label>\t<mode>
#   <request-id>.merge-order-v1    ->   <task-id>\t<pr-url>
#
# The extension names the shape, which is what stops a merge order from being
# read as an answer. The keyed-answer line is byte for byte an input line of
# `bin/fm-captain-hold.sh answers`, and `answers` below prints those bytes back
# out unchanged: no sanitizing, no truncation, no re-encoding. The mode field is
# passed through exactly as written, INCLUDING a value this adapter does not
# recognize, because what a mode means belongs to the intake, which skips what
# it does not accept.
#
# EVERY BYTE IN THE SPOOL IS UNTRUSTED INPUT, NEVER INSTRUCTION. It arrives from
# a process outside this repository. No record is executed, interpolated into a
# shell, or read as permission. Record bytes reach a shell variable nowhere in
# this file: the scan, the claim, and the capture are one perl program that
# receives only adapter-supplied arguments, and every captured byte is escaped
# to a single safe line before it is printed. A record cannot forge a capture
# line, because a newline cannot survive that escaping.
#
# COMPLETENESS: the writer links a fully written file into place rather than
# appending to it, so PRESENCE IN THE SPOOL IS THE COMPLETENESS GUARANTEE this
# adapter relies on - the atomic link, not a size, a settle delay, or a marker
# file. The required trailing newline is checked as corroboration on top of that
# guarantee, not as a substitute for it: a writer that ever appended would be
# caught by it, and a torn record is reported rather than fed.
#
# CONSUMED EXACTLY ONCE, BY RENAME. A claim is `rename(2)` out of the spool root
# into `<spool>/consumed/` for a well-formed record and `<spool>/rejected/` for
# a malformed one, and the rename happens BEFORE the record is printed. Rename
# is exclusive on its source, so two readers racing one record produce exactly
# one claim and the loser sees ENOENT. Nothing is ever deleted and no path
# outside the spool directory is touched.
#
# A malformed record MUST be claimed too. Leaving it in place would make the
# next poll find it again immediately, so a single unreadable byte sequence
# would wake the fleet forever. It is moved to `rejected/`, reported once, and
# never repaired and never run.
#
# The residual window, stated plainly: a poll killed between the rename and the
# runner reading its output leaves that record claimed but never announced. It
# is still on disk under `consumed/`, so it is recoverable by hand, which is
# strictly better than a source that destroys what it hands over - but this is
# not at-least-once, no-loss, or lossless delivery, and must never be described
# as any of those.
#
# NOTHING ENDS A WATCHED DIRECTORY. A spool has no last record and no close
# event, so `terminal` never exits 0 and this source is never retired
# automatically. It ends exactly one way: an operator runs `retire`. A missing
# or unusable spool directory is deliberately NOT terminal either, because a
# directory can be recreated and retiring the source on its absence would
# silently stop watching a spool the writer is about to restore.
#
# SILENCE IS POSITIVELY DETERMINED. `silent` exits 0 only for a capture that
# parses as this format, completely, and declares and presents zero records -
# an absence visible in the capture, never one inferred. Everything else is
# announced: a malformed record, a truncated capture, an error capture, an empty
# file, and anything this adapter cannot parse. That asymmetry is the point. The
# runner discards a child stderr, so an error must reach stdout inside a capture
# to be seen at all, and an unparsable capture that classified `empty` would
# silence exactly the breakage a handler most needs to hear about.
#
# HANDLING A CAPTURED MERGE ORDER is a handler procedure, not an adapter one,
# and it is owned by the `process-event-sources` skill. `read` prints a pointer
# to it beside every order it presents. The short of it: a merge press is the
# captain explicit merge word for that one pull request, and it rests on five
# mandatory safeguards - resolve the pull request from the task own
# `state/<task-id>.meta` `pr=` record and treat the address in the order as a
# cross-check whose mismatch is a refusal, re-verify at handling time that the
# pull request is still open and green, refuse and report a red or changed pull
# request, merge only through bin/fm-pr-merge.sh, and echo the merge with the
# full URL. This adapter performs none of that; it only makes the order visible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

ANSWER_EXT='.keyed-answer-v1'
ORDER_EXT='.merge-order-v1'

# One record is one short line. The cap is generous against the shipped shapes
# and exists so a huge file dropped into the spool is reported as oversized
# rather than read into memory.
MAX_RECORD_BYTES=8192
# A batch bound, not a spool bound. Whatever a batch leaves behind is claimed by
# the next poll, which the runner starts immediately.
MAX_BATCH_RECORDS=256
# Well under the runner FM_PROCEVENT_MAX_OUTPUT_BYTES default of 1048576, so a
# capture is never truncated mid-line. `answers` still refuses an incomplete
# capture, because a cut record line would decode to a PREFIX of a real answer
# and the intake would durably record that prefix as what the captain said.
MAX_BATCH_BYTES=262144
SCAN_INTERVAL_DEFAULT=5
SCAN_INTERVAL_MAX=300
# A spool that is missing for this many consecutive scans stops being treated as
# a transient recreate and is reported. Bounded rather than infinite so a
# genuinely broken spool is announced instead of watched in silence forever.
MISSING_SPOOL_LIMIT=12

# Canonical identity is physical, not the path string: two names for one
# directory are one spool and must never become two owners of it.
resolve_spool() {  # <spool-dir>
  local dir=${1-} real
  [ -n "$dir" ] || usage
  case "$dir" in *$'\n'*) die "spool paths cannot contain newlines" ;; esac
  real=$(perl -MCwd=realpath -e 'my $p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$dir" 2>/dev/null) \
    || die "cannot resolve the spool path: $dir"
  [ -n "$real" ] || die "cannot resolve the spool path: $dir"
  printf '%s\n' "$real"
}

cmd_source_id() {
  local dir=${1-} real
  [ -n "$dir" ] || usage
  [ "$#" -eq 1 ] || usage
  real=$(resolve_spool "$dir") || exit 1
  [ -d "$real" ] || die "spool directory does not exist: $dir"
  if command -v shasum >/dev/null 2>&1; then
    printf 'answer-spool-%s\n' "$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'answer-spool-%s\n' "$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

# Seconds between scans. FM_ANSWER_SPOOL_INTERVAL is a bounded test and operator
# override; a malformed or out-of-range value is refused rather than quietly
# rounded, because silently changing a watch cadence is how a bound stops
# meaning anything.
scan_interval() {
  local interval=${FM_ANSWER_SPOOL_INTERVAL-}
  if [ -z "$interval" ]; then
    printf '%s\n' "$SCAN_INTERVAL_DEFAULT"
    return 0
  fi
  case "$interval" in
    ''|*[!0-9]*) die "FM_ANSWER_SPOOL_INTERVAL must be whole seconds from 1 to $SCAN_INTERVAL_MAX: $interval" ;;
  esac
  { [ "$interval" -ge 1 ] && [ "$interval" -le "$SCAN_INTERVAL_MAX" ]; } \
    || die "FM_ANSWER_SPOOL_INTERVAL must be whole seconds from 1 to $SCAN_INTERVAL_MAX: $interval"
  printf '%s\n' "$interval"
}

cmd_arm() {
  local dir=${1-} id real binding
  [ -n "$dir" ] || usage
  [ "$#" -eq 1 ] || usage
  case "$dir" in *$'\n'*) die "spool paths cannot contain newlines" ;; esac
  scan_interval >/dev/null
  # Created here rather than demanded of the operator: source identity is the
  # resolved path, so the directory must exist before it can be named, and
  # failing arm after a successful bind would leave a binding with no source.
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    (umask 077; mkdir -p "$dir") || die "cannot create the spool directory: $dir"
  fi
  real=$(resolve_spool "$dir") || exit 1
  [ ! -L "$real" ] && [ -d "$real" ] || die "spool path is not a directory: $dir"
  id=$(cmd_source_id "$real") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" register answer-spool "$id" \
    -- "$SCRIPT_DIR/fm-procevent-answer-spool.sh" poll "$real" || exit 1
  printf 'armed: %s\n' "$id"
  printf 'spool: %s\n' "$real"
  binding=$("$SCRIPT_DIR/fm-captain-hold.sh" binding "$id" 2>/dev/null) || binding=
  if [ -z "$binding" ]; then
    printf 'note: this source is not bound to the keyed-answer intake, so captured answers feed nothing\n'
    printf 'note: bind it BEFORE arming with: %s bind %s\n' "$SCRIPT_DIR/fm-captain-hold.sh" "$id"
  fi
}

cmd_retire() {
  local dir=${1-} id
  [ -n "$dir" ] || usage
  [ "$#" -eq 1 ] || usage
  id=$(cmd_source_id "$dir") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# An error the handler must see. The runner discards a child stderr, so this
# goes to stdout inside a capture; it carries no end marker, so it classifies
# `unknown` and is announced rather than silenced.
emit_error_capture() {  # <spool> <token> <message>
  printf 'answer-spool/1\n'
  printf 'spool: %s\n' "$1"
  printf 'error: %s %s\n' "$2" "$3"
}

# Scan the spool, claim a bounded batch by rename, and print one capture.
# Exit 0 printed a capture, 1 found nothing claimable, 3 could not scan.
#
# Everything that touches a record lives in here, in one perl program that
# receives only adapter-supplied arguments. A record byte never reaches a shell
# variable, a command line, or a filename this adapter composes.
scan_and_claim() {  # <spool> <token>
  perl -e '
    use strict;
    use warnings;
    use Fcntl qw(:mode O_RDONLY O_NOFOLLOW);

    my ($spool, $token, $max_records, $max_bytes, $max_record_bytes,
        $answer_ext, $order_ext) = @ARGV;

    # A bound on the collision-suffix search below, not a real-world ceiling:
    # reaching it means the destination directory already holds this many
    # same-named claims under this token, which is skipped rather than risked.
    my $MAX_COLLISION_ATTEMPTS = 1000;

    # Every captured byte goes through this before it is printed, so a record
    # can never introduce a newline and forge a capture line.
    sub esc {
      my ($s) = @_;
      return "" unless defined $s;
      $s =~ s/\\/\\\\/g;
      $s =~ s/\t/\\t/g;
      $s =~ s/\n/\\n/g;
      $s =~ s/\r/\\r/g;
      $s =~ s/([\x00-\x1f\x7f])/sprintf("\\x%02x", ord($1))/ge;
      return $s;
    }

    # A name is a positional field in the capture, so it additionally may not
    # contain a space.
    sub esc_name {
      my ($s) = @_;
      $s = esc($s);
      $s =~ s/ /\\x20/g;
      return $s;
    }

    # Structure only. What a task id, an answer, a mode, or an address MEANS is
    # decided downstream; this refuses only what cannot be transported as the
    # shipped shape. An empty key is refused here rather than passed on because
    # the runner discards the intake output, so a key the intake skips would be
    # invisible - reporting it as malformed is the only way a handler sees it.
    sub validate_record {
      my ($kind, $data) = @_;
      return ("malformed", "empty", "") if length($data) == 0;
      return ("malformed", "no-trailing-newline", $data)
        unless substr($data, -1) eq "\n";
      my $body = substr($data, 0, length($data) - 1);
      return ("malformed", "multi-line", $body) if index($body, "\n") >= 0;
      my @f = split(/\t/, $body, -1);
      if ($kind eq "answer") {
        return ("malformed", "field-count", $body) unless @f == 3 || @f == 4;
        return ("malformed", "empty-key", $body) unless length $f[0];
      } else {
        return ("malformed", "field-count", $body) unless @f == 2;
        return ("malformed", "empty-field", $body)
          unless length($f[0]) && length($f[1]);
      }
      return ("ok", "", $body);
    }

    opendir(my $dh, $spool) or exit 3;
    my @names = readdir($dh);
    closedir($dh);

    my @candidates;
    my $ignored = 0;
    for my $name (sort @names) {
      next if $name eq "." || $name eq "..";
      next if $name eq "consumed" || $name eq "rejected";
      if (length($name) > length($answer_ext)
          && substr($name, -length($answer_ext)) eq $answer_ext) {
        push @candidates, [$name, "answer"];
        next;
      }
      if (length($name) > length($order_ext)
          && substr($name, -length($order_ext)) eq $order_ext) {
        push @candidates, [$name, "order"];
        next;
      }
      $ignored++;
    }
    exit 1 unless @candidates;

    for my $sub ("consumed", "rejected") {
      my $path = "$spool/$sub";
      mkdir($path, 0700) unless -e $path || -l $path;
      exit 3 if -l $path;
      exit 3 unless -d $path;
    }

    my @claimed;
    my $bytes = 0;
    for my $candidate (@candidates) {
      last if scalar(@claimed) >= $max_records;
      last if $bytes >= $max_bytes;
      my ($name, $kind) = @$candidate;
      my $src = "$spool/$name";
      my ($verdict, $reason, $payload) = ("ok", "", "");

      if ($name !~ /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/) {
        ($verdict, $reason) = ("malformed", "unsafe-name");
      } else {
        my @ls = lstat($src);
        next unless @ls;
        if (!S_ISREG($ls[2])) {
          # A symlink, a directory, or a device named like a record. Never
          # opened, never followed, and claimed into rejected/ by a rename that
          # moves the link itself and nothing it points at.
          ($verdict, $reason) = ("malformed", "not-a-regular-file");
        } elsif ($ls[7] > $max_record_bytes) {
          ($verdict, $reason) = ("malformed", "too-large");
        } else {
          my $fh;
          if (sysopen($fh, $src, O_RDONLY | O_NOFOLLOW)) {
            my @fs = stat($fh);
            if (!@fs || !S_ISREG($fs[2]) || $fs[0] != $ls[0] || $fs[1] != $ls[1]) {
              # The entry changed between the lstat and the open; the bytes now
              # open are not the ones that were checked.
              ($verdict, $reason) = ("malformed", "not-a-regular-file");
            } else {
              binmode $fh;
              my $data = "";
              my $readable = 1;
              while (1) {
                my $chunk;
                my $n = sysread($fh, $chunk, 65536);
                if (!defined $n) { $readable = 0; last }
                last if $n == 0;
                $data .= $chunk;
                last if length($data) > $max_record_bytes;
              }
              if (!$readable) {
                ($verdict, $reason) = ("malformed", "unreadable");
              } elsif (length($data) > $max_record_bytes) {
                ($verdict, $reason) = ("malformed", "too-large");
              } else {
                ($verdict, $reason, $payload) = validate_record($kind, $data);
              }
            }
            close($fh);
          } else {
            ($verdict, $reason) = ("malformed", "unreadable");
          }
        }
      }

      my $destdir = ($verdict eq "ok") ? "$spool/consumed" : "$spool/rejected";
      my $dest = "$destdir/$name";
      if (-e $dest || -l $dest) {
        my $free = 0;
        for (my $i = 1; $i <= $MAX_COLLISION_ATTEMPTS; $i++) {
          my $try = "$destdir/$name.$token.$i";
          next if -e $try || -l $try;
          $dest = $try;
          $free = 1;
          last;
        }
        # No free destination found: leave the record in the spool root and
        # skip it this batch rather than risk the rename below overwriting a
        # previously consumed or quarantined record. Nothing is ever deleted.
        next unless $free;
      }
      # The claim. Exclusive on its source, so a racing reader loses here and
      # the record is announced exactly once.
      next unless rename($src, $dest);

      my $line;
      if ($verdict eq "ok") {
        $line = "record: $kind " . esc_name($name) . " " . esc($payload);
      } else {
        $line = "record: malformed " . esc_name($name) . " $reason " . esc($payload);
      }
      push @claimed, $line;
      $bytes += length($line) + 1;
    }
    exit 1 unless @claimed;

    my $declared = scalar(@claimed);
    binmode STDOUT;
    my $out = "answer-spool/1\n";
    $out .= "spool: " . esc($spool) . "\n";
    $out .= "declared_records: $declared\n";
    $out .= "ignored_entries: $ignored\n";
    $out .= "$_\n" for @claimed;
    $out .= "end: $declared\n";
    print $out;
    exit 0;
  ' "$1" "$2" "$MAX_BATCH_RECORDS" "$MAX_BATCH_BYTES" "$MAX_RECORD_BYTES" \
    "$ANSWER_EXT" "$ORDER_EXT"
}

cmd_poll() {
  local dir=${1-} interval missing=0 rc token
  [ -n "$dir" ] || usage
  [ "$#" -eq 1 ] || usage
  case "$dir" in *$'\n'*) die "spool paths cannot contain newlines" ;; esac
  interval=$(scan_interval) || exit 1
  token="$$-$(date +%s 2>/dev/null || printf '0')"
  while :; do
    if [ -L "$dir" ] || [ ! -d "$dir" ]; then
      missing=$((missing + 1))
      if [ "$missing" -ge "$MISSING_SPOOL_LIMIT" ]; then
        emit_error_capture "$dir" spool-unavailable \
          'the spool directory is missing or is not a directory'
        return 1
      fi
      sleep "$interval"
      continue
    fi
    missing=0
    scan_and_claim "$dir" "$token"
    rc=$?
    case "$rc" in
      0) return 0 ;;
      1) sleep "$interval" ;;
      *)
        emit_error_capture "$dir" scan-failed \
          'the spool directory could not be scanned'
        return 1
        ;;
    esac
  done
}

# The one reader of a capture, shared by classify, answers, and read so the
# three can never disagree about what a capture says. <mode> is a fixed word
# supplied by this adapter, never by input.
present() {  # <mode> <result-file>
  perl -e '
    use strict;
    use warnings;

    my ($mode, $path) = @ARGV;
    open(my $fh, "<", $path) or exit 3;
    binmode $fh;
    my @lines = <$fh>;
    close $fh;
    chomp @lines;

    # The inverse of the capture escaping. An unknown escape is refused rather
    # than guessed at, so a capture this adapter did not write decodes to
    # nothing instead of to something plausible.
    sub unesc {
      my ($s) = @_;
      my $out = "";
      while (length $s) {
        if    ($s =~ s/\A\\\\//)                { $out .= "\\" }
        elsif ($s =~ s/\A\\t//)                 { $out .= "\t" }
        elsif ($s =~ s/\A\\n//)                 { $out .= "\n" }
        elsif ($s =~ s/\A\\r//)                 { $out .= "\r" }
        elsif ($s =~ s/\A\\x([0-9a-f]{2})//)    { $out .= chr(hex($1)) }
        elsif ($s =~ m/\A\\/)                   { return undef }
        else { $s =~ s/\A([^\\]+)//; $out .= $1 }
      }
      return $out;
    }

    sub esc {
      my ($s) = @_;
      return "" unless defined $s;
      $s =~ s/\\/\\\\/g;
      $s =~ s/\t/\\t/g;
      $s =~ s/\n/\\n/g;
      $s =~ s/\r/\\r/g;
      $s =~ s/([\x00-\x1f\x7f])/sprintf("\\x%02x", ord($1))/ge;
      return $s;
    }

    my $header = (@lines && $lines[0] eq "answer-spool/1") ? 1 : 0;
    my ($spool, $declared, $ignored, $end, $error);
    my (@answers, @orders, @malformed);
    my $unparsed = 0;
    for my $i (1 .. $#lines) {
      my $line = $lines[$i];
      if ($line =~ /\Aspool: (.*)\z/)             { $spool = $1; next }
      if ($line =~ /\Adeclared_records: (\d+)\z/) { $declared = $1; next }
      if ($line =~ /\Aignored_entries: (\d+)\z/)  { $ignored = $1; next }
      if ($line =~ /\Aend: (\d+)\z/)              { $end = $1; next }
      if ($line =~ /\Aerror: ([a-z-]+) (.*)\z/)   { $error = "$1 $2"; next }
      if ($line =~ /\Arecord: (answer|order) ([^ ]+) (.*)\z/) {
        push @{ $1 eq "answer" ? \@answers : \@orders }, [$2, $3];
        next;
      }
      if ($line =~ /\Arecord: malformed ([^ ]+) ([a-z-]+) ?(.*)\z/) {
        push @malformed, [$1, $2, $3];
        next;
      }
      $unparsed++;
    }

    my $presented = scalar(@answers) + scalar(@orders) + scalar(@malformed);
    my $complete = ($header
      && !$unparsed
      && !defined($error)
      && defined($declared)
      && defined($end)
      && $end == $declared
      && $presented == $declared) ? 1 : 0;

    if ($mode eq "classify") {
      if    (!$header)                     { print "unknown\n" }
      elsif (defined $error)               { print "unknown\n" }
      elsif (@orders)                      { print "orders\n" }
      elsif (@answers)                     { print "answers\n" }
      elsif (@malformed)                   { print "rejected\n" }
      elsif ($complete && $declared == 0)  { print "empty\n" }
      else                                 { print "unknown\n" }
      exit 0;
    }

    if ($mode eq "answers") {
      # A truncated capture cuts mid-line, and a cut record decodes to a PREFIX
      # of a real answer. Feeding that would durably record something the
      # captain never said, so an incomplete capture yields nothing at all and
      # is announced instead; its records remain under the spool consumed/
      # directory for recovery by hand.
      exit 1 unless $complete;
      my @out;
      for my $a (@answers) {
        my $decoded = unesc($a->[1]);
        exit 1 unless defined $decoded;
        push @out, $decoded;
      }
      binmode STDOUT;
      print "$_\n" for @out;
      exit 0;
    }

    # read
    sub fields_of {
      my ($encoded) = @_;
      my $decoded = unesc($encoded);
      return undef unless defined $decoded;
      return [split(/\t/, $decoded, -1)];
    }

    print "ANSWER SPOOL CAPTURE\n";
    print "spool: ", (defined $spool ? $spool : "(unset)"), "\n";
    print "declared_records: ", (defined $declared ? $declared : "(unset)"), "\n";
    print "presented_records: $presented\n";
    print "answer_records: ", scalar(@answers), "\n";
    print "merge_order_records: ", scalar(@orders), "\n";
    print "malformed_records: ", scalar(@malformed), "\n";
    print "ignored_entries: ", (defined $ignored ? $ignored : "(unset)"), "\n";
    print "unparsed_lines: $unparsed\n";
    print "complete: ", ($complete ? "yes" : "no"), "\n";
    print "error: $error\n" if defined $error;
    print "\n";

    if (@answers) {
      print "KEYED ANSWERS\n";
      my $n = 0;
      for my $a (@answers) {
        $n++;
        my $f = fields_of($a->[1]);
        print "ANSWER $n of ", scalar(@answers), "\n";
        print "record: $a->[0]\n";
        if (!defined $f) {
          print "undecodable: yes\n";
          next;
        }
        print "task_id: ", esc(defined $f->[0] ? $f->[0] : ""), "\n";
        print "answer: ",  esc(defined $f->[1] ? $f->[1] : ""), "\n";
        print "label: ",   esc(defined $f->[2] ? $f->[2] : ""), "\n";
        print "mode: ",    esc(defined $f->[3] ? $f->[3] : ""), "\n";
      }
      print "fed: when this source is bound, the runner already passed these lines to the keyed-answer intake; when it is not bound, they are fed to nothing and appear only here\n";
      print "END KEYED ANSWERS\n";
    } else {
      print "KEYED ANSWERS: (none)\n";
    }
    print "\n";

    if (@orders) {
      print "MERGE ORDERS\n";
      my $n = 0;
      for my $o (@orders) {
        $n++;
        my $f = fields_of($o->[1]);
        print "ORDER $n of ", scalar(@orders), "\n";
        print "record: $o->[0]\n";
        if (!defined $f) {
          print "undecodable: yes\n";
          next;
        }
        print "task_id: ", esc(defined $f->[0] ? $f->[0] : ""), "\n";
        print "pr_url: ",  esc(defined $f->[1] ? $f->[1] : ""), "\n";
      }
      print "handling: load the process-event-sources skill and follow its merge-order procedure\n";
      print "handling: the address above is a CROSS-CHECK against the task own pr= record, never the source of it\n";
      print "END MERGE ORDERS\n";
    } else {
      print "MERGE ORDERS: (none)\n";
    }
    print "\n";

    if (@malformed) {
      print "MALFORMED RECORDS\n";
      my $n = 0;
      for my $m (@malformed) {
        $n++;
        print "MALFORMED $n of ", scalar(@malformed), "\n";
        print "record: $m->[0]\n";
        print "reason: $m->[1]\n";
        print "bytes: $m->[2]\n";
      }
      print "quarantined: these were moved to the spool rejected/ directory, reported, and not repaired\n";
      print "END MALFORMED RECORDS\n";
    } else {
      print "MALFORMED RECORDS: (none)\n";
    }
    print "\n";
    print "END ANSWER SPOOL CAPTURE ($presented of ",
      (defined $declared ? $declared : "?"), ")\n";
    exit 0;
  ' "$1" "$2"
}

require_result() {  # <result-file>
  [ -n "${1-}" ] || usage
  [ -f "$1" ] && [ ! -L "$1" ] || die "result file does not exist: $1"
}

cmd_classify() {
  [ "$#" -eq 1 ] || usage
  require_result "${1-}"
  present classify "$1"
}

cmd_answers() {
  [ "$#" -eq 1 ] || usage
  require_result "${1-}"
  present answers "$1"
}

cmd_read() {
  [ "$#" -eq 1 ] || usage
  require_result "${1-}"
  present read "$1"
}

# Nothing ends a watched directory; see the header. This source is retired only
# by an operator running `retire`.
cmd_terminal() {
  [ "$#" -eq 1 ] || usage
  require_result "${1-}"
  return 1
}

# Silence is an absence visible in the capture, never one inferred; see the
# header. A capture that does not parse as this format is announced, because a
# check that could not complete is not proof that nothing arrived.
cmd_silent() {
  [ "$#" -eq 1 ] || usage
  require_result "${1-}"
  [ "$(present classify "$1")" = empty ]
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  silent)    shift; cmd_silent "$@" ;;
  answers)   shift; cmd_answers "$@" ;;
  read)      shift; cmd_read "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
