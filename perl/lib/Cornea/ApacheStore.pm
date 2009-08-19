package Cornea::ApacheStore;
use strict;

use Apache2::Const qw ( OK DECLINED NOT_FOUND );
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use APR::Table;
use WWW::Curl::Easy;

my %methods = (
  'store' => 'PUT',
  'delete' => 'DELETE',
  'copy' => 'COPY',
);

sub path {
  my $self = shift;
  my ($serviceId, $assetId, $repId) = @_;
  my $config = Cornea::Config->new();
  my $base = $config->get("Storage::path");
  $assetId = "$assetId"; # Treat it as a string.
  if($assetId =~ /^\d+$/ and length $assetId < 4) {
    # pad it back with zeros so we can has it successfully
    $assetId = ("0" x (4 - length $assetId)) . $assetId;
  }
  if($assetId =~ /(.*)(...)/) {
    return "$base/$serviceId/$repId/$2/$1";
  }
  die "Could not convert '$assetId' to path\n";
}

sub xml {
  my $self = shift;
  my $r = shift;
  $r->status(shift);
  $r->content_type('text/xml');
  $r->print(shift);
  return OK;
}

sub copy {
  my $self = shift;
  my $r = shift;
  my ($serviceId, $assetId, $repId) = @_;
  my $copied = 0;
  my $errbuf;
  my $path;

  my @nodes = split /\s*,\s*/, $r->headers_in->get('X-Cornea-Node');
  eval {
    $path = $self->path($serviceId, $assetId, $repId);
    die "Invalid cornea node\n" unless(@nodes);
    foreach my $node (@nodes) {
      my $url = "http://$node/$serviceId/$assetId/$repId";
      my $file = IO::File->new(">$path");
      my $curl = WWW::Curl::Easy->new();
      $curl->setopt(CURLOPT_URL, $url);
      $curl->setopt(CURLOPT_FILE, $file);
      $curl->setopt(CURLOPT_WRITEFUNCTION,
                    sub { my ($data, $file) = @_;
                          return $file->syswrite($data);
                        });
      $curl->perform();
      $file->close();
      $errbuf = $curl->errbuf;
      my $code = $curl->getinfo(CURLINFO_HTTP_CODE);
      if ($code == 200 and -e $path and not -z $path) {
        $copied = 1;
        last;
      }
    }
  };
  if($@ or not $copied) {
    my $error = $@ || $errbuf;
    unlink($path) if $path;
    return $self->xml($r, 500, "<error>$error</error>");
  }
  return $self->xml($r, 200, "<success />");
}
sub delete {
  my $self = shift;
  my $r = shift;
  my ($serviceId, $assetId, $repId) = @_;
  my $path;
  eval { $path = $self->path($serviceId, $assetId, $repId); };
  return $self->xml($r, 500, "<error>$@</error>") if $@;
  return $self->xml($r, 500, "<error>$!</error>") if not unlink($path);
  return $self->xml($r, 200, "<success />");
}

sub store {
  my $self = shift;
  my $r = shift;
  my ($serviceId, $assetId, $repId) = @_;
  my $path;

  eval {
    $path = $self->path($serviceId, $assetId, $repId);
    my $file = IO::File->new(">$path") || die "cannot open $path";
    my $buffer;
    while($r->read($buffer, (1024*128)) > 0) {
      if($file->write($buffer) != length($buffer)) {
        die "short write on $path"
      }
    }
    $file->flush();
    $file->close();
  };
  if($@) {
    unlink($path) if $path;
    print STDERR $@;
    return $self->xml($r, 500, "<error>$@</error>");
  }
  return $self->xml($r, 200, "<success />");
}

sub handler {
  my ($self, $r) = @_;
  # Sometimes Apache acts oddly
  ($r, $self) = ($self, __PACKAGE__) if (ref $self eq 'Apache2::RequestRec');

  my $uri = $r->uri;
  # Only allow /cornea/<method>[/args/go/here]
  return DECLINED
    unless ($uri =~ /^\/cornea\/(([^\/]+)(\/.*)?)/ or not exists $methods{$2});
  my ($method, @args) = split /\//, $1;
  # only allow the right HTTP method
  return $self->xml($r, 403, '<error>'.$r->method().' disallowed</error>')
    unless ($r->method() eq $methods{'store'});
  # do it.
  return $self->$method($r, @args);
}
1;
