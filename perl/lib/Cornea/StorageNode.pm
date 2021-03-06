package Cornea::StorageNode;
use strict;
use WWW::Curl::Easy;

=pod

=item id()

The unique identifier.

=item state()

The state of the node: {open,closed,offline,decommissioned}

=item total_storage()

The total storage in kilobytes.

=item used_storage()

The amount of storage used in kilobytes.

=item fqdn()

The fully-qualified domain name of the node.

=item location()

Described as DataCenter/Cage/Row/Rack/PDU

=item distance()

Distance between two nodes w.r.t. their location.

=cut

sub new_from_row {
  my $class = shift;
  my $hash = shift;
  bless $hash, $class;
}
sub id { shift->{storage_node_id}; }
sub state { shift->{state}; }
sub total_storage { shift->{total_storage}; }
sub used_storage { shift->{used_storage}; }
sub fqdn { shift->{fqdn}; }
sub ip { shift->{ip}; }
sub location { shift->{location}; }

sub distance() {
  my $self = shift;
  my $other = shift;
  my @a = split /\//, $self->location();
  my @b = split /\//, $other->location();

  my $dist = 0;
  while(defined(my $a_v = shift @a) || defined(my $b_v = shift @b)) {
    $dist <<= 1;
    $dist |= 1 if($a_v != $b_v);
  }
  return $dist;
}

sub _curl_help_write {
  my ($data, $d) = @_;
  $$d .= $data;
  return length($data);
}

sub api_url {
  my $self = shift;
  my $function = shift;
  my $url = "http://" . $self->ip() . ":8091/cornea/$function";
  $url .= "/" . join ("/", @_) if @_;
  return $url;
}
sub asset_url {
  my $self = shift;
  return "http://" . $self->ip() . "/" . join ("/", @_);
}
sub put {
  my $self = shift;
  my $source = shift;
  my ($serviceId,$assetId,$repId) = @_;
  my $response_data = '';

  # Transform nodes into lists.
  $source = Cornea::StorageNodeList->new($source)
    if(ref $source eq 'Cornea::StorageNode');

  if(ref $source eq 'Cornea::StorageNodeList') {
    # This is a storage node(list) from which to copy.
    my $url = $self->api_url('copy', @_);
    my $curl = new WWW::Curl::Easy;
    my $ips = join ',', map { $_->ip() } ($source->items());
    $curl->setopt(CURLOPT_URL, $url);
    $curl->setopt(CURLOPT_HTTPHEADER, [ "X-Cornea-Node: $ips" ]);
    print STDERR "COPY $url (X-Cornea-Node: $ips)\n" if $main::DEBUG;
    $curl->setopt(CURLOPT_CUSTOMREQUEST, "COPY");
    $curl->setopt(CURLOPT_FILE, \$response_data);
    $curl->setopt(CURLOPT_WRITEFUNCTION, \&_curl_help_write);
    $curl->setopt(CURLOPT_WRITEHEADER, undef);
    my $retcode = $curl->perform();
    my $code = $curl->getinfo(CURLINFO_HTTP_CODE);
    return 1 if($retcode == 0 && $code == 200);
    return (0, "$code: $response_data");
  }
  else {
    # This is an actual asset
    my $url = $self->api_url('store', @_);
    my $curl = new WWW::Curl::Easy;
    $source->seek(0,2) || die "seek failed\n";
    my $len = $source->tell();
    $source->seek(0,0) || die "seek failed\n";
    $curl->setopt(CURLOPT_URL, $url);
    $curl->setopt(CURLOPT_READFUNCTION,
                  sub { my $buf; $source->read($buf, $_[0]); return $buf; } );
    $curl->setopt(CURLOPT_INFILESIZE, $len);
    $curl->setopt(CURLOPT_UPLOAD, 1);
    $curl->setopt(CURLOPT_CUSTOMREQUEST, "PUT");
    $curl->setopt(CURLOPT_FILE, \$response_data);
    $curl->setopt(CURLOPT_WRITEFUNCTION, \&_curl_help_write);
  
    my $retcode = $curl->perform();
    my $code = $curl->getinfo(CURLINFO_HTTP_CODE);
    return 1 if($retcode == 0 && $code == 200);
    return (0, "$code: $response_data");
  }
}

sub delete {
  my $self = shift;
  my ($serviceId,$assetId,$repId) = @_;
  my $url = $self->api_url('delete', @_);
  my $curl = new WWW::Curl::Easy;
  $curl->setopt(CURLOPT_URL, $url);
  $curl->setopt(CURLOPT_CUSTOMREQUEST, "DELETE");

  my $retcode = $curl->perform();
  return 1 if($retcode == 0 && $curl->getinfo(CURLINFO_HTTP_CODE) == 200);
  return 0;
}

sub fetch {
  my $self = shift;
  my ($serviceId,$assetId,$repId) = @_;
  my $url = $self->asset_url(@_);
  my $file = IO::File->new_tmpfile();
  my $curl = new WWW::Curl::Easy;
  $curl->setopt(CURLOPT_URL, $url);
  $curl->setopt(CURLOPT_FILE, $file);
  $curl->setopt(CURLOPT_WRITEFUNCTION,
                sub { my ($data, $file) = @_;
                      return $file->syswrite($data);
                    });

  my $retcode = $curl->perform();
  return $file if($retcode == 0 && $curl->getinfo(CURLINFO_HTTP_CODE) == 200);
  return undef;
}

1;
