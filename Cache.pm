#!/usr/local/bin/perl -w

package Tie::Cache;
use strict;
use vars qw($VERSION $Debug);

$VERSION = .10;
$Debug = 0; # set to 1 for summary, 2 for debug output

=pod

=head1 NAME

Tie::Cache - LRU Cache in Memory

=head1 SYNOPSIS

 use Tie::Cache;
 tie %cache, 'Tie::Cache', 100, { Debug => 1 };   
 tie %cache2, 'Tie::Cache', { MaxCount => 100, MaxBytes => 1000 };
 tie %cache3, 'Tie::Cache', 100, { Debug => 1 , WriteSync => 0};   

 # Options ##################################################################
 #
 # Debug =>	 0 - DEFAULT, no debugging output
 #		 1 - prints cache statistics upon destroying
 #		 2 - prints detailed debugging info
 #
 # MaxCount =>	 Maximum entries in cache.
 # MaxBytes =>   Maximum bytes in cache, sum of keys and values.
 # MaxSize  =>   Maximum size of each cache entry. Larger entries are not cached.
 #                   This helps prevent much of the cache being flushed when 
 #                   you set an exceptionally large entry.
 # WriteSync =>  1 - DEFAULT, write() when data is dirtied for 
 #                   TRUE CACHE (see below)
 #               0 - write() dirty data as late as possible, when leaving 
 #                   cache, or when cache is being DESTROY'd
 #
 ############################################################################

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
On a WinNT PII 300, writes to the hash were done at a rate 
3100 per second, and reads from the hash at 6300 per second.   
Work has been done to optimize refreshing cache entries that are 
frequently read from, code like $cache{entry}, which moves the 
entry to the end of the linked list internally.

=cut Documentation continues at the end of the module.

sub TIEHASH {
    my($class, $max_count, $options) = @_;

    if(ref($max_count)) {
	$options = $max_count;
	$max_count = $options->{MaxCount};
    }
	
    unless($max_count || $options->{MaxBytes}) {
	die('you must specify cache size with either MaxBytes or MaxCount');
    }

    my $sync = exists($options->{WriteSync}) ? $options->{WriteSync} : 1;

    bless { 
	   # how many items to cache
	   max_count=> $max_count, 
	   
	   # max bytes to cache
	   max_bytes => $options->{MaxBytes},
	   
	   # max size (in bytes) of an individual cache entry
	   max_size => $options->{MaxSize} || $options->{MaxBytes},
	   
	   # current sizes
	   count=>0, 
	   bytes=>0,
	   
	   # inner structures
	   head=>0, 
	   tail=>0, 
	   nodes=>{},
	   'keys'=>[],
	   
	   # statistics
	   hit => 0,
	   miss => 0,
	   
	   # config
	   sync => $sync,
	   dbg => $options->{Debug} || $Debug
	   
	
    }, $class;
}

# override to write data leaving cache
sub write { undef; }
# commented this section out for speed
#    my($self, $key, $value) = @_;
#    1;
#}

# override to get data if not in cache, should return $value
# associated with $key
sub read { undef; }
# commented this section out for speed
#    my($self, $key) = @_;
#    undef;
#}

sub FETCH {
    my($self, $key) = @_;

    my $node = $self->{nodes}{$key};
    if($node) {
	# refresh node's entry
	$self->{hit}++; # if $self->{dbg};

	# we used to call delete then insert, but we streamlined code
	if(my $after = $node->{after}) {
	    $self->{dbg} > 1 and $self->print("update() node $node to tail of list");
	    # reconnect the nodes
	    my $before = $after->{before} = $node->{before};
	    if($before) {
		$before->{after} = $after;
	    } else {
		$self->{head} = $after;
	    }

	    # place at the end
	    $self->{tail}{after} = $node;
	    $node->{before} = $self->{tail};
	    $node->{after} = undef;
	    $self->{tail} = $node; # always true after this
	} else {
	    # if there is nothing after node, then we are at the end already
	    # so don't do anything to move the nodes around
	    die("this node is the tail, so something's wrong") 
		unless($self->{tail} eq $node);
	}

	$self->print("FETCH [$key, $node->{value}]") if ($self->{dbg} > 1);
	$node->{value};
    } else {
	# we have a cache miss here
	$self->{miss}++; # if $self->{dbg};

	# its fine to always insert a node, even when we have an undef,
	# because even if we aren't a sub-class, we should assume use
	# that would then set the entry.  This model works well with
	# sub-classing and reads() that might want to return undef as
	# a valid value.
	$self->print("read() for key $key") if $self->{dbg} > 1;
	my $value = $self->read($key);

	if(defined $value) {
	    if(defined $self->{max_size}) {
		# check max size of entry, that it not exceed max size
		my $length = length($value) + length($key);
		if($length > $self->{max_size}) {
		    $self->print("direct read() [$key, $value]") if ($self->{dbg} > 1);
		    return $value;
		}
	    } 
	    # if we get here, we should insert the new node
	    $node = &create_node($self, \$key, \$value);
	    &insert($self, $node);
	    $value;
	} else {
	    undef;
	}
    }
}

sub STORE {
    my($self, $key, $value) = @_;
    my $node;

    $self->print("STORE [$key,$value]") if ($self->{dbg} > 1);

    # check max size of entry, that it not exceed max size
    my $length = length($value) + length($key);
    if(defined($self->{max_size}) and ($length > $self->{max_size})) {
	$self->print("direct write() [$key, $value]") if ($self->{dbg} > 1);
        $self->write($key, $value);	
	return $value;
    }

   # do not cache undefined values
    defined($value) || return(undef);

    # do we have node already ?
    if($self->{nodes}{$key}) {
	$node = &delete($self, $key);
	$node->{value} = $value;
    } 
    
    # insert new node  
    $node ||= &create_node($self, \$key, \$value, $length);
    &insert($self, $node);

    # if the data is sync'd call write now, otherwise defer the data
    # writing, but mark it dirty so it can be cleanup up at the end
    if($self->{sync}) {
	$self->print("sync write() [$key, $value]") if $self->{dbg} > 1;
	$self->write($key, $value);
    } else {
	$node->{dirty} = 1;
    }    

    $value;
}

sub DELETE {
    my($self, $key) = @_;
    
    $self->print("DELETE $key") if ($self->{dbg} > 1);
    my $node = $self->delete($key);
    my $value = $node->{value};
    undef $node;

    $value;
}

sub CLEAR {
    my($self) = @_;

    $self->print("CLEAR CACHE") if ($self->{dbg} > 1);
    my $node;
    while($node = $self->{head}) {
	$self->delete($self->{head}{key});
	if($node->{dirty}) {
	    $self->print("dirty write() [$node->{key}, $node->{value}]") if ($self->{dbg} > 1);
	    $self->write($node->{key}, $node->{value});
	}
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
    if($self->{dbg}) {
	if($self->{hit} || $self->{miss}) {
	    $self->{hit_ratio} = 
		sprintf("%4.3f", $self->{hit} / ($self->{hit} + $self->{miss})); 
	}
	$self->print($self->pretty_self());
	if($self->{dbg} > 1) {
	    $self->print($self->pretty_chains());
	}
    }
    
    $self->print("DESTROYING") if $self->{dbg} > 1;
    $self->CLEAR();
    
    1;
}

####PERL##LRU##TIE##CACHE##PERL##LRU##TIE##CACHE##PERL##LRU##TIE##CACHE
## Helper Routines
####PERL##LRU##TIE##CACHE##PERL##LRU##TIE##CACHE##PERL##LRU##TIE##CACHE

# we use scalar_refs for the data for speed
sub create_node {
    my($self, $key, $value, $length) = @_;
    (defined($$key) && defined($$value)) 
	|| die("need more localized data than $$key and $$value");
    {
	key=>$$key, 
	value=>$$value, 
	bytes=> defined $length ? $length : length($$key)+length($$value),
    };
}

sub insert {
    my($self, $new_node) = @_;
    
    $new_node->{after} = 0;
    $new_node->{before} = $self->{tail};
    $self->print("insert() [$new_node->{key}, $new_node->{value}]") if ($self->{dbg} > 1);
    
#    my $key = $new_node->{key};
    $self->{nodes}{$new_node->{key}} = $new_node;

    # current sizes
    $self->{count}++;
    $self->{bytes} += $new_node->{bytes};

    if($self->{tail}) {
	$self->{tail}{after} = $new_node;
    } else {
	$self->{head} = $new_node;
    }
    $self->{tail} = $new_node;

    ## if we are too big now, remove head
    while(($self->{max_count} && ($self->{count} > $self->{max_count})) ||
	  ($self->{max_bytes} && ($self->{bytes} > $self->{max_bytes}))) 
    {
	if($self->{dbg} > 1) {
	    $self->print("current/max: ".
			 "bytes ($self->{bytes}/$self->{max_bytes}) ".
			 "count ($self->{count}/$self->{max_count}) "
			 );
	}
	my $old_node = $self->delete($self->{head}{key});
	if($old_node->{dirty}) {
	    $self->print("dirty write() [$old_node->{key}, $old_node->{value}]") 
		if ($self->{dbg} > 1);
	    $self->write($old_node->{key}, $old_node->{value});
	}
#	if($self->{dbg} > 1) {
#	    $self->print("after delete - bytes $self->{bytes}; count $self->{count}");
#	}
    }
    
    1;
}

sub delete {
    my($self, $key) = @_;    
    my $node = $self->{nodes}{$key} || return;
#    return unless $node;

    $self->print("delete() [$key, $node->{value}]") if ($self->{dbg} > 1);

    my $before = $node->{before};
    my $after = $node->{after};

#    my($before, $after) = $node->{before,after};
    if($before) {
	($before->{after} = $after);
    } else {
	$self->{head} = $after;
    }

    if($after) {
	($after->{before} = $before);
    } else {
	$self->{tail} = $before;
    }

    delete $self->{nodes}{$key};
    $self->{bytes} -= $node->{bytes};
    $self->{count}--;
    
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
	next unless defined $self->{$_};
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

=head1 BENCMARKS

There is another simpler LRU cache implementation in CPAN, 
Tie::Cache::LRU, which has the same basic size limiting 
functionality, and for this functionality, the exact same 
interface.  This other cache takes writes about 20% faster 
but cache reads are about 50% slower.  Here are some numbers 
to illustrate:

 Module			Read/s	Write/s	Delete/s Platform
 ------			------	-------	-------- --------
 Tie::Cache v.08	 6300	3100	4800	 perl 5.00404 WinNT PII300
 Tie::Cache::LRU v.05	 3700	3700	4500	 perl 5.00404 WinNT PII300
 --
 Tie::Cache v.08	10600	5300	8500	 perl 5.00503 Solaris PII300

The reason for using an cache is that you are probably
doing more reads than writes, so you will likely want to 
use this module, but may want to consider Tie::Cache::LRU
if your i/o mix is write heavy.  

=head1 TRUE CACHE

To use class as a true cache, which acts as the sole interface 
for some data set, subclass the real cache off Tie::Cache, 
with @ISA = qw( 'Tie::Cache' ) notation.  Then override
the read() method for behavior when there is a cache miss,
and the write() method for behavior when the cache's data 
changes.

When WriteSync is 1 or TRUE (DEFAULT), write() is called immediately
when data in the cache is modified.  If set to 0, data that has 
been modified in the cache gets written out when the entries are deleted or
during the DESTROY phase of the cache object, usually at the end of
a script.

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
 my $Debug = $ARGV[2] || 1;

 tie %cache, 'My::Cache', $cache_size, {Debug => $Debug};   

 # load the cache with new data, each through its contents,
 # and then reload in reverse order.
 for(1..$num_to_cache) { print "read data $_: $cache{$_}\n" }
 while(my($k, $v) = each %cache) { print "each data $k: $v\n"; }
 for(my $i=$num_to_cache; $i>0; $i--) { print "read data $i: $cache{$i}\n"; }

 # clear cache in 2 ways, write will flush out to disk
 %cache = ();
 undef %cache;

=head1 NOTES

Many thanks to all those who helped me make this module a reality, 
including:

	:) Tom Hukins who provided me insight and motivation for
	   finishing this module.
	:) Jamie McCarthy, for trying to make Tie::Cache be all
	   that it can be.
	:) Rob Fugina who knows how to "TRULY CACHE".

=head1 AUTHOR

Please send any questions or comments to Joshua Chamas
at chamas@alumni.stanford.org

=head1 COPYRIGHT

Copyright (c) 1999 Joshua Chamas.
All rights reserved. This program is free software; 
you can redistribute it and/or modify it under the same 
terms as Perl itself. 

=cut
