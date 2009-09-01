package Cornea::Queue;
use strict;
use YAML ();
use Cornea::Config;
use Net::Stomp;
use Digest::MD5 qw/md5_hex/;

my $_g_cornea_queue;

sub __reconnect {
  my $self = shift;
  my $config = Cornea::Config->new();
  my $stomp;

  if($self->{stomp}) {
    eval { $self->{stomp}->disconnect(); };
    delete $self->{stomp};
  }
  my $stomphosts = $config->get_list("MQ::hostname");
  foreach my $location ( @$stomphosts ) {
    my ($hostname, $port) = split /:/, $location;
    $port ||= 61613;
    eval {
      $stomp = Net::Stomp->new( { hostname => $hostname,
                                     port => $port });
      $stomp->connect( { login => $config->get("MQ::login"),
                         passcode => $config->get("MQ::passcode") }) ||
        die "could not connect to stomp on $hostname\n";
    };
    last unless $@;
    $stomp = undef;
  }
  if($stomp) {
    foreach (@{$self->{queues}}) {
      $stomp->subscribe( {
        exchange => '',
        destination => "$_",
       'auto-delete' => 'false',
        durable => 'true', ack => 'client',
      } );
    }
  }
  $self->{stomp} = $stomp;
}

sub new {
  my $class = shift;
  my $self = bless { queues => [@_] }, $class;
  $self->__reconnect();
  return $self;
}

sub enqueue {
  # enqueue can act as both a method and a static class function
  my $self;

  if(UNIVERSAL::isa($_[0], __PACKAGE__)) {
    $self = shift;
  }
  else {
    $_g_cornea_queue ||= __PACKAGE__->new();
    $self = $_g_cornea_queue;
  }
  my $retried = 0;
  my $config = Cornea::Config->new();
  my ($op, $detail) = @_;
  print STDERR "enqueue($op)\n" if $main::DEBUG;
  my $destination = $config->get("MQ::queue_" . lc($op));
  my $payload = YAML::Dump($op, $detail);
  my $fid = md5_hex($payload);
  while(1) {
    my $response = undef;
    my $frame = {};
    eval {
      $response = $self->{stomp}->send(
        { destination => $destination,
          exchange => '',
         'delivery-mode' => 2,
          receipt => $fid,
          body => $payload }
      );
      $frame = $self->{stomp}->receive_frame();
    };
    return 1
      if($frame->{'command'} eq 'RECEIPT' and
         $frame->{'headers'}->{'receipt-id'} eq $fid);
    print STDERR $@ if $@;
    last if ($retried);
    $self->__reconnect();
    $retried = 1;
  }
  return 0;
}

sub dequeue {
  # dequeue only acts as a method because it must be connected to a queue.
  my $self = shift;
  my $sub = shift;
 
  my $frame = $self->{stomp}->receive_frame; 
  my ($op, $detail) = YAML::Load($frame->body);
  $sub->($op, $detail);
  $self->{stomp}->ack( { frame => $frame } );
}

sub worker {
  my $self = shift;
  my $sub = shift;
  while(1) {
    $self->dequeue($sub);
  }
}

1;
