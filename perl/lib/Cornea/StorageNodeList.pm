package Cornea::StorageNodeList;
use strict;

sub new {
  my $class = shift;
  $class = ref($class) ? ref $class : $class;
  bless {}, $class;
}

sub items {
  my $self = shift;
  return values (%$self);
}

sub remove {
  my $self = shift;
  my $node = shift;
  delete $self->{$node->fqdn()};
}

sub add {
  my $self = shift;
  my $node = shift;
  $self->{$node->fqdn()} = $node;
}

sub count {
  my $self = shift;
  return scalar(keys %$self);
}

sub removeWithin {
  my $self = shift;
  my $reference = shift;
  my $distance = shift;
  foreach my $n (values %$self) {
    foreach my $r ($reference->items()) {
      if($r->distance($n) < $distance) {
        $self->remove($n);
        last;
      }
    }
  }
}

sub copy {
  my $self = shift;
  my $copy = $self->new();
  foreach my $n ($self->items) {
    $copy->add($n);
  }
  return $copy;
}

1;
