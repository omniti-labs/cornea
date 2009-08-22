package Cornea::Queue;
use strict;
use YAML ();
use Cornea::Config;
use Net::Stomp;

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
                         passcode => $config->get("MQ::passcode") } ) || 
        die "could not connect to stomp on $hostname\n";
    };
    last unless $@;
    $stomp = undef;
  }
  if($stomp) {
    foreach (@{$self->{queues}}) {
      $stomp->subscribe( { destination => $_, ack => 'client' } );
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
  my $self = shift;
  my $retried = 0;
  my $config = Cornea::Config->new();
  my ($op, $detail) = @_;
  my $payload = YAML::Dump($op, $detail);
  while(1) {
    last unless eval {
      $self->{stomp}->send(
        { destination => $config->get("MQ::queue_" . lc($op)),
          body => $payload }
      );
    } || $@;
    last if ($retried);
    $self->__reconnect();
    $retried = 1;
  }
  return 1;
}

sub dequeue {
  my $self = shift;
  my $sub = shift;
 
  my $frame = $self->{stomp}->receive_frame; 
  my ($op, $detail) = YAML::Load($frame->body);
  if($sub->($op, $detail)) {
    $self->{stomp}->ack( { frame => $frame } );
  }
}

sub worker {
  my $self = shift;
  my $sub = shift;
  while(1) {
    $self->dequeue($sub);
  }
}

1;
