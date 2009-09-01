package Cornea::Queue;
use strict;
use YAML ();
use Cornea::Config;
use Net::Stomp;

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
  # dequeue only acts as a method because it must be connected to a queue.
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
