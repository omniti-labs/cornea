package Cornea::StorageNodeList;
use strict;

sub new {
  my $class = shift;
  $class = ref($class) ? ref $class : $class;
  my $self = bless {}, $class;
  foreach (@_) { $self->add($_); }
  $self;
}

sub items {
  my $self = shift;
  return values (%$self);
}

sub remove {
  my $self = shift;
  my $node = shift;
  if (ref $node eq 'CODE') {
    foreach ($self->items()) {
      $self->remove($_) if $node->($_);
    }
  }
  else {
    delete $self->{$node->fqdn()};
  }
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
