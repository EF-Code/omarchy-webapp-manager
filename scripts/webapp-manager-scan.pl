#!/usr/bin/perl

use strict;
use warnings;
use bytes;
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
    $values{$key} = $value;
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

sub is_webapp_exec {
  my ($exec_line) = @_;
  return index($exec_line, "omarchy-launch-webapp") >= 0
    || index($exec_line, "omarchy-webapp-handler") >= 0;
}

sub safe_url {
  my ($value) = @_;
  return "" unless defined $value;
  return $1 if $value =~ /(https?:\/\/[^\s"]+)/i;
  return "";
}

sub icon_state {
  my ($icon, $data_home) = @_;
  return "missing" unless defined $icon && length $icon;

  if ($icon =~ /\A\//) {
    return -f $icon ? "present" : "missing";
  }

  # Keep named-icon checks inside the expected user icon directory.
  return "unknown" unless $icon =~ /\A[A-Za-z0-9._-]+\z/;
  my $icon_dir = File::Spec->catdir(
    $data_home,
    "icons",
    "hicolor",
    "256x256",
    "apps",
  );
  return "present"
    if -f File::Spec->catfile($icon_dir, "$icon.png")
    || -f File::Spec->catfile($icon_dir, "$icon.svg")
    || -f File::Spec->catfile($icon_dir, "$icon.webp");
  return "unknown";
}

sub scan_apps {
  my ($desktop_dir, $data_home) = @_;
  return { ok => json_true(), apps => [] } unless -d $desktop_dir;

  opendir(my $dir, $desktop_dir)
    or emit_error("scan-failed", "Could not open the user applications directory.", 1);

  my @entries;
  while (defined(my $name = readdir($dir))) {
    next if $name eq "." || $name eq "..";
    next unless $name =~ /\.desktop\z/;

    my $path = File::Spec->catfile($desktop_dir, $name);
    next if byte_length($path) > MAX_DESKTOP_PATH_BYTES;

    (my $desktop_id = $name) =~ s/\.desktop\z//;
    next if byte_length($desktop_id) > MAX_DESKTOP_ID_BYTES;

    my ($values) = read_desktop_entry($path);
    next unless $values && is_webapp_exec($values->{Exec} // "");

    my $exec_line = $values->{Exec} // "";
    my $name_value = exists $values->{Name} ? $values->{Name} : $desktop_id;
    next if byte_length($name_value) > MAX_NAME_BYTES;

    my $url = safe_url($exec_line);
    next if byte_length($url) > MAX_URL_BYTES;

    my $icon = $values->{Icon} // "";
    my $mime_types = $values->{MimeType} // "";
    my $is_handler = index($exec_line, "omarchy-webapp-handler") >= 0;
    my $kind = $is_handler ? "handler" : "webapp";
    my $status = $is_handler ? "handler" : ($url ne "" ? "healthy" : "invalid-url");
    my $icon_status = icon_state($icon, $data_home);
    $status = "missing-icon" if $status eq "healthy" && $icon_status eq "missing";

    my $entry = {
      desktopFile => $path,
      desktopId   => $desktop_id,
      name        => $name_value,
      url         => $url,
      exec        => $exec_line,
      icon        => $icon,
      iconState   => $icon_status,
      mimeTypes   => $mime_types,
      kind        => $kind,
      status      => $status,
    };

    my $candidate = { ok => json_true(), apps => [@entries, $entry] };
    emit_error("output-limit", "The web-app scan result is too large.", 1)
      if encoded_size($candidate) > MAX_OUTPUT_BYTES;
    push @entries, $entry;
    last if @entries >= MAX_APPS;
  }
  closedir($dir);

  return { ok => json_true(), apps => \@entries };
}

sub read_exec {
  my ($path) = @_;
  my ($values, $error) = read_desktop_entry($path);
  emit_error("$error", "The selected desktop file could not be read safely.", 2)
    unless $values;
  return { ok => json_true(), exec => ($values->{Exec} // "") };
}

if (@ARGV >= 1 && $ARGV[0] eq "--read-exec") {
  shift @ARGV;
  emit_error("invalid-arguments", "A desktop file path is required.", 2)
    unless @ARGV == 1;
  emit_payload(read_exec($ARGV[0]), 0);
}

emit_error("invalid-arguments", "A desktop directory and data directory are required.", 2)
  unless @ARGV == 2;

emit_payload(scan_apps($ARGV[0], $ARGV[1]), 0);
