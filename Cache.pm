=head1 NAME

Tie::Cache - LRU Cache in Memory

=head1 SYNOPSIS

 use Tie::Cache;
 tie %cache, 'Tie::Cache', 100, {Debug => 1};   

 # cache supports normal tied hash functions
 $cache{1} = 2;       # STORE
 print "$cache{1}\n"; # FETCH

 # FIRSTKEY, NEXTKEY
 while(($k, $v) = each %cache) { print "$k: $v\n"; } 
 
 delete $cache{1};    # DELETE
 %cache = ();         # CLEAR

=head1 DESCRIPTION

This module implements a least recently used (LRU) cache in memory
through a tie interface.  Any time data is stored in the tied hash,
that key/value pair has an entry time associated with it, and 
as the cache fills up, those members of the cache that are
the oldest are removed to make room for new entries.

So, the cache only "remembers" the last written entries, up to the 
size of the cache.  This can be especially useful if you access 
great amounts of data, but only access a minority of the data a 
majority of the time. 

The implementation is a hash, for quick lookups, 
overlaying a doubly linked list for quick insertion and deletion.
On a PII 300, writes to the hash were done at a rate of at 
least 3000 per second.

=cut Documentation continues at the end of the module.

package Tie::Cache;
use Carp qw(cluck);
$Tie::Cache::Debug = 0; # set to 1 for summary, 2 for debug output

sub TIEHASH {
    my($self, $max_size, $options) = @_;
    die('you must specify a size for the cache') unless $max_size;

    $Debug ||= $options->{Debug};
    bless { 
	# how many items to cache
	max=> $max_size, 
	
	# current size
	count=>0, 

	# inner structures
	head=>0, 
	tail=>0, 
	nodes=>{},
	'keys'=>[],

	# statistics
	hit => 0,
	miss => 0

    }, $self;
}

# override to write data leaving cache
sub write {
    my($self, $key, $value) = @_;
    1;
}

# override to get data if not in cache, should return $value
# associated with $key
sub read {
    my($self, $key) = @_;
    undef;
}

sub FETCH {
    my($self, $key) = @_;

    my $node = $self->{nodes}{$key};
    if($node) {
	# refresh node's entry
	$self->{hit} += 1 if $Debug;
	$self->delete($node->{key});
	$self->insert($node);
    } else {
	# we have a cache miss here
	$self->{miss} += 1 if $Debug;
	$self->print("read() for key $key") if $Debug > 1;
	$value = $self->read($key);
	if(defined $value) {
	    $node = $self->STORE($key, $value);
	}
    }
    
    if($node) {
	$self->print("FETCH [$key, $node->{value}]")
	    if ($Debug > 1);
	$node->{value};
    } else {
	$self->print("FETCH nothing") if $Debug > 1;
	undef;
    }
}

sub STORE {
    my($self, $key, $value) = @_;
    my $node;

    # do we have node already ?
    if($self->{nodes}{$key}) {
	$node = $self->delete($key);
	$node->{value} = $value;
    } 
    
    # insert new node  
    $node ||= {key=>$key, value=>$value};
    $self->insert($node);

    $self->print("STORE [$key,$value]")
	if ($Debug > 1);

    $node;
}

sub DELETE {
    my($self, $key) = @_;
    
    $self->print("DELETE $key") if ($Debug > 1);
    my $node = $self->delete($key);
    my $value = $node->{value};
    undef $node;

    $value;
}

sub CLEAR {
    my($self) = @_;

    $self->print("CLEAR CACHE") if ($Debug > 1);
    my $node;
    while($node = $self->{head}) {
	$self->delete($self->{head}{key});
	$self->print("write() [$node->{key}, $node->{value}]") if ($Debug > 1);
	$self->write($node->{key}, $node->{value});
    }

    1;
}

sub EXISTS {
    my($self, $key) = @_;
    exists $self->{nodes}{$key};
}
    
# firstkey / nextkey emulate keys() and each() behavior by
# taking a snapshot of all the nodes at firstkey, and 
# iterating through the keys with nextkey
#
# this method therefore will only supports one each() / keys()
# happening during any given time.
#
sub FIRSTKEY {
    my($self) = @_;

    $self->{'keys'} = [];
    my $node = $self->{head};
    while($node) {
	push(@{$self->{'keys'}}, $node->{key});
	$node = $node->{after};
    }
	
    shift @{$self->{'keys'}};
}

sub NEXTKEY {
    my($self, $lastkey) = @_;
    shift @{$self->{'keys'}};
}

sub DESTROY {
    my($self) = @_;

    # if debugging, snapshot cache before clearing
    $self->{hit_ratio} = 
	sprintf("%4.3f", $self->{hit} / ($self->{hit} + $self->{miss})); 
    $self->print($self->pretty_self()) if $Debug;

    $self->CLEAR();
    
    1;
}

####PERL##LRU##TIE##CACHE##PERL##LRU##TIE##CACHE##PERL##LRU##TIE##CACHE
## Helper Routines
####PERL##LRU##TIE##CACHE##PERL##LRU##TIE##CACHE##PERL##LRU##TIE##CACHE

sub insert {
    my($self, $new_node) = @_;
    
    $new_node->{after} = 0;
    $new_node->{before} = $self->{tail};

#    $self->print("inserting node: [$new_node->{key}, $new_node->{value}]");
    my $key = $new_node->{key};
    $self->{nodes}{$key} = $new_node;
    $self->{count}++;

    if($self->{tail}) {
	$self->{tail}{after} = $new_node;
    } else {
	$self->{head} = $new_node;
    }
    $self->{tail} = $new_node;

    ## if we are too big now, remove head
    if($self->{count} > $self->{max}) {
	my $old_node = $self->delete($self->{head}{key});
	$self->print("write() [$old_node->{key}, $old_node->{value}]") 
	    if ($Debug > 1);
	$self->write($old_node->{key}, $old_node->{value});
    }

    1;
}

sub delete {
    my($self, $key) = @_;
    
    my($node) = $self->{nodes}{$key};
    return unless $node;

    if($node->{before}) {
	($node->{before}{after} = $node->{after});
    } else {
	$self->{head} = $node->{after};
    }

    if($node->{after}) {
	($node->{after}{before} = $node->{before});
    } else {
	$self->{tail} = $node->{before};
    }

    delete $self->{nodes}{$key};
    $self->{count}--;
    
    $self->print("delete() $key: $node->{value}") 
	if ($Debug > 1);

    $node;
}

sub print {
    my($self, $msg) = @_;
    print "$self: $msg\n";
}

sub pretty_self {
    my($self) = @_;
    
    my(@prints);
    for(sort keys %{$self}) { 
	next unless $self->{$_};
	push(@prints, "$_=>$self->{$_}"); 
    }

    "{ " . join(", ", @prints) . " }";
}

sub pretty_chains {
    my($self) = @_;
    my($str);
    my $k = $self->FIRSTKEY();

    $str .= "[head]->";
    my($curr_node) = $self->{head};
    while($curr_node) {
	$str .= "[$curr_node->{key},$curr_node->{value}]->";
	$curr_node = $curr_node->{after};
    }
    $str .= "[tail]->";

    $curr_node = $self->{tail};
    while($curr_node) {
	$str .= "[$curr_node->{key},$curr_node->{value}]->";
	$curr_node = $curr_node->{before};
    }
    $str .= "[head]";

    $str;
}

1;

__END__

=head1 INSTALLATION

Tie::Cache installs easily using the make or nmake commands as
shown below.  Otherwise, just copy Cache.pm to $PERLLIB/site/Tie

	> perl Makefile.PL
	> make
        > make test 
	> make install

        * use nmake for win32
        ** you can also just copy Cache.pm to $perllib/Tie

=head1 TRUE CACHE

To use class as a true cache, which acts as the sole interface 
for some data set, subclass the real cache off Tie::Cache, 
with @ISA = qw( 'Tie::Cache' ) notation.  Then override
the read() method for behavior when there is a cache miss,
and the write() method for behavior when the cache's old data
is removed from the cache, often called write through.

=head1 TRUE CACHE EXAMPLE

 use Tie::Cache;

 # personalize the Tie::Cache object, by inheriting from it
 package My::Cache;
 @ISA = qw(Tie::Cache);

 # override the read() and write() member functions
 # these tell the cache what to do with a cache miss or flush
 sub read { 
    my($self, $key) = @_; 
    print "cache miss for $key, read() data\n";
    rand() * $key; 
 }
 sub write { 
    my($self, $key, $value) = @_;
    print "flushing [$key, $value] from cache, write() data\n";
 }

 my $cache_size   = $ARGV[0] || 2;
 my $num_to_cache = $ARGV[1] || 4;   
 my $debug = $ARGV[2] || 1;

 tie %cache, 'My::Cache', $cache_size, {Debug => $debug};   

 # load the cache with new data, each through its contents,
 # and then reload in reverse order.
 for(1..$num_to_cache) { print "read data $_: $cache{$_}\n" }
 while(my($k, $v) = each %cache) { print "each data $k: $v\n"; }
 for(my $i=$num_to_cache; $i>0; $i--) { print "read data $i: $cache{$i}\n"; }

 # clear cache in 2 ways, write will flush out to disk
 %cache = ();
 undef %cache;

=head1 NOTES

Many thanks to Tom Hukins who provided me insight and motivation for
finishing this module.

=head1 AUTHOR

Please send any questions or comments to Joshua Chamas
at chamas@alumni.stanford.org

=head1 COPYRIGHT

Copyright (c) 1998 Joshua Chamas.
All rights reserved. This program is free software; 
you can redistribute it and/or modify it under the same 
terms as Perl itself. 

=cut
