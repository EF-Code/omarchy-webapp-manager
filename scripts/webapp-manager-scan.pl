#!/usr/bin/perl

use strict;
use warnings;
use bytes;
use Encode qw(decode encode FB_CROAK);
use Fcntl qw(O_RDONLY O_NOFOLLOW O_NONBLOCK S_IFMT S_IFREG);
use File::Spec;
use JSON::PP qw(encode_json);

use constant {
  MAX_APPS                 => 256,
  MAX_FILE_BYTES           => 64 * 1024,
  READ_CHUNK_BYTES         => 8 * 1024,
  MAX_OUTPUT_BYTES         => 2 * 1024 * 1024,
  MAX_DESKTOP_PATH_BYTES   => 512,
  MAX_DESKTOP_ID_BYTES     => 160,
  MAX_NAME_BYTES           => 120,
  MAX_EXEC_BYTES           => 512,
  MAX_URL_BYTES            => 2048,
  MAX_ICON_BYTES           => 256,
  MAX_ICON_PATH_BYTES      => 1024,
  MAX_MIME_TYPES_BYTES     => 512,
};

my %FIELD_LIMITS = (
  Name     => MAX_NAME_BYTES,
  Exec     => MAX_EXEC_BYTES,
  Icon     => MAX_ICON_BYTES,
  MimeType => MAX_MIME_TYPES_BYTES,
);

sub json_true { return JSON::PP::true; }
sub json_false { return JSON::PP::false; }

sub byte_length {
  return length($_[0]);
}

sub decode_utf8 {
  my ($value) = @_;
  my $decoded = eval { decode("UTF-8", $value, FB_CROAK) };
  return undef if $@;
  return $decoded;
}

sub error_payload {
  my ($code, $message) = @_;
  return {
    ok    => json_false(),
    error => { code => $code, message => $message },
  };
}

sub encoded_size {
  my ($payload) = @_;
  return byte_length(encode_json($payload)) + 1;
}

sub emit_payload {
  my ($payload, $exit_code) = @_;
  my $json = encode_json($payload);

  if (byte_length($json) + 1 > MAX_OUTPUT_BYTES) {
    $payload = error_payload(
      "output-limit",
      "The web-app scan result is too large.",
    );
    $json = encode_json($payload);
    $exit_code = 1;
  }

  print $json, "\n";
  exit($exit_code);
}

sub emit_error {
  my ($code, $message, $exit_code) = @_;
  emit_payload(error_payload($code, $message), $exit_code);
}

sub read_bounded {
  my ($fh) = @_;
  my $content = "";
  my $total = 0;

  while (1) {
    my $remaining = MAX_FILE_BYTES + 1 - $total;
    last if $remaining <= 0;

    my $want = $remaining < READ_CHUNK_BYTES
      ? $remaining
      : READ_CHUNK_BYTES;
    my $chunk = "";
    my $read = sysread($fh, $chunk, $want);

    if (!defined $read) {
      # O_NONBLOCK makes pipes/FIFOs fail fast instead of waiting for a writer.
      return undef;
    }
    last if $read == 0;

    $total += $read;
    return undef if $total > MAX_FILE_BYTES;
    $content .= $chunk;
  }

  return $content;
}

sub parse_desktop_entry {
  my ($content) = @_;
  my %values;
  my $in_desktop_entry = 0;

  for my $line (split /\n/, $content, -1) {
    $line =~ s/\r\z//;

    if (!$in_desktop_entry) {
      if ($line eq "[Desktop Entry]") {
        $in_desktop_entry = 1;
      }
      next;
    }

    last if $line =~ /^\[/;
    next unless $line =~ /\A(Name|Exec|Icon|MimeType)=(.*)\z/s;

    my ($key, $value) = ($1, $2);
    next if exists $values{$key};
    return (undef, "field-too-large")
      if byte_length($value) > $FIELD_LIMITS{$key};
    my $decoded = decode_utf8($value);
    return (undef, "invalid-encoding") unless defined $decoded;
    $values{$key} = $decoded;
  }

  return (\%values, undef);
}

sub read_desktop_entry {
  my ($path) = @_;
  my $fh;

  return (undef, "unsafe-path")
    if byte_length($path) > MAX_DESKTOP_PATH_BYTES;

  # O_NOFOLLOW closes the pathname symlink race. O_NONBLOCK ensures a file
  # replaced by a FIFO cannot stall the panel before fstat() rejects it.
  sysopen($fh, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    or return (undef, "unsafe-path");
  binmode($fh);

  my @stat = stat($fh);
  my $is_regular_user_file = @stat
    && (($stat[2] & S_IFMT) == S_IFREG)
    && $stat[4] == $<;
  if (!$is_regular_user_file) {
    close($fh);
    return (undef, "unsafe-path");
  }

  if ($stat[7] > MAX_FILE_BYTES) {
    close($fh);
    return (undef, "file-too-large");
  }

  my $content = read_bounded($fh);
  close($fh);
  return (undef, "file-too-large") unless defined $content;

  my ($values, $parse_error) = parse_desktop_entry($content);
  return (undef, $parse_error) if $parse_error;
  return ($values, undef);
}

sub parse_launch {
  my ($exec_line) = @_;
  return undef unless defined $exec_line;

  if ($exec_line =~ /\Aomarchy-launch-webapp ((?i:https?):\/\/[^\s"']+)\z/) {
    return {
      kind => "webapp",
      url  => $1,
    };
  }

  if ($exec_line =~ /\Aomarchy-webapp-handler-([A-Za-z0-9][A-Za-z0-9._-]{0,63}) %u\z/) {
    my $handler = $1;
    my $handler_path = "/usr/bin/omarchy-webapp-handler-$handler";
    my @handler_stat = lstat($handler_path);
    return undef unless @handler_stat
      && (($handler_stat[2] & S_IFMT) == S_IFREG)
      && $handler_stat[4] == 0
      && ($handler_stat[2] & 0111);

    return {
      kind    => "handler",
      handler => $handler,
      url     => "",
    };
  }

  return undef;
}

sub named_icon_path {
  my ($icon, $data_home) = @_;
  return undef unless defined $icon && length $icon;

  # Omarchy's web-app installer writes downloaded/user-supplied icons here
  # and stores only the icon basename in the desktop entry. Keep this lookup
  # confined to that directory; theme lookup remains a QML fallback.
  return undef unless $icon =~ /\A[A-Za-z0-9._-]+\z/;
  my $icon_dir = File::Spec->catdir(
    $data_home,
    "icons",
    "hicolor",
    "256x256",
    "apps",
  );
  my $icon_name = encode("UTF-8", $icon);

  for my $extension (qw(png svg webp)) {
    my $candidate = File::Spec->catfile($icon_dir, "$icon_name.$extension");
    next if byte_length($candidate) > MAX_ICON_PATH_BYTES;

    # lstat() deliberately rejects a symlink. This keeps the emitted path
    # tied to a user-owned regular file when QML opens it later.
    my @stat = lstat($candidate);
    next unless @stat
      && (($stat[2] & S_IFMT) == S_IFREG)
      && $stat[4] == $<;

    my $json_candidate = decode_utf8($candidate);
    return $json_candidate if defined $json_candidate;
  }

  return undef;
}

sub icon_state {
  my ($icon, $data_home, $resolved_path, $path_checked) = @_;
  return "missing" unless defined $icon && length $icon;

  if ($icon =~ /\A\//) {
    return -f encode("UTF-8", $icon) ? "present" : "missing";
  }

  # Keep named-icon checks inside the expected user icon directory.
  return "unknown" unless $icon =~ /\A[A-Za-z0-9._-]+\z/;
  return defined $resolved_path ? "present" : "unknown" if $path_checked;
  return "present"
    if defined $resolved_path || defined named_icon_path($icon, $data_home);
  return "unknown";
}

sub scan_apps {
  my ($desktop_dir, $data_home) = @_;
  return { ok => json_true(), apps => [] } unless -d $desktop_dir;

  opendir(my $dir, $desktop_dir)
    or emit_error("scan-failed", "Could not open the user applications directory.", 1);

  my @entries;
  my $output_bytes = encoded_size({ ok => json_true(), apps => [] });
  while (defined(my $name = readdir($dir))) {
    next if $name eq "." || $name eq "..";
    next unless $name =~ /\.desktop\z/;
    next if $name =~ /[\x00-\x1f\x7f]/;

    my $path = File::Spec->catfile($desktop_dir, $name);
    next if byte_length($path) > MAX_DESKTOP_PATH_BYTES;

    (my $desktop_id = $name) =~ s/\.desktop\z//;
    next if byte_length($desktop_id) > MAX_DESKTOP_ID_BYTES;

    my $json_path = decode_utf8($path);
    my $json_desktop_id = decode_utf8($desktop_id);
    next unless defined $json_path && defined $json_desktop_id;

    my ($values) = read_desktop_entry($path);
    next unless $values;

    my $exec_line = $values->{Exec} // "";
    my $launch = parse_launch($exec_line);
    next unless $launch;

    my $name_value = exists $values->{Name} ? $values->{Name} : $json_desktop_id;
    next if byte_length($name_value) > MAX_NAME_BYTES;

    my $url = $launch->{url};
    next if byte_length($url) > MAX_URL_BYTES;

    my $icon = $values->{Icon} // "";
    my $mime_types = $values->{MimeType} // "";
    my $is_handler = $launch->{kind} eq "handler";
    my $kind = $launch->{kind};
    my $status = $is_handler ? "handler" : "healthy";
    my $resolved_icon_path = named_icon_path($icon, $data_home);
    my $icon_path = $resolved_icon_path // "";
    my $icon_status = icon_state(
      $icon,
      $data_home,
      $resolved_icon_path,
      1,
    );
    $status = "missing-icon" if $status eq "healthy" && $icon_status eq "missing";

    my $entry = {
      desktopFile => $json_path,
      desktopId   => $json_desktop_id,
      name        => $name_value,
      url         => $url,
      exec        => $exec_line,
      icon        => $icon,
      iconState   => $icon_status,
      iconPath    => $icon_path,
      mimeTypes   => $mime_types,
      kind        => $kind,
      status      => $status,
    };

    my $entry_bytes = byte_length(encode_json($entry));
    my $candidate_bytes = $output_bytes + (@entries ? 1 : 0) + $entry_bytes;
    emit_error("output-limit", "The web-app scan result is too large.", 1)
      if $candidate_bytes > MAX_OUTPUT_BYTES;
    $output_bytes = $candidate_bytes;
    push @entries, $entry;
    last if @entries >= MAX_APPS;
  }
  closedir($dir);

  return { ok => json_true(), apps => \@entries };
}

sub read_launch {
  my ($path) = @_;
  my ($values, $error) = read_desktop_entry($path);
  emit_error("$error", "The selected desktop file could not be read safely.", 2)
    unless $values;

  my $launch = parse_launch($values->{Exec} // "");
  emit_error("not-webapp", "The selected desktop file is not an Omarchy web app.", 2)
    unless $launch;

  return { ok => json_true(), launch => $launch };
}

if (@ARGV >= 1 && $ARGV[0] eq "--read-launch") {
  shift @ARGV;
  emit_error("invalid-arguments", "A desktop file path is required.", 2)
    unless @ARGV == 1;
  emit_payload(read_launch($ARGV[0]), 0);
}

emit_error("invalid-arguments", "A desktop directory and data directory are required.", 2)
  unless @ARGV == 2;

emit_payload(scan_apps($ARGV[0], $ARGV[1]), 0);
