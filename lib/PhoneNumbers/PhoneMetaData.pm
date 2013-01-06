package PhoneNumbers::PhoneMetaData;

use strict;
use warnings;
use Carp::Clan;
use JSON::XS;
use File::Slurp;
use Data::Dumper;

my $JSON = JSON::XS->new;

sub new {
	my ($class, $proto) = @_;
	$proto or croak 'proto is required';
	return bless +{
		%$proto,
	}, $class;
}

sub read_from_file {
	my ($class, $args) = @_;
	my $file_path = $args->{file_path} or croak 'file_path is required';

	unless (-e $file_path) {
		croak "$file_path does not exist";
	}

	my $json = read_file($file_path);
	my $proto;
	eval {
		$proto = $JSON->decode($json);
	};
	if ($@) {
		croak $@;
	}
	
	return $class->new($proto);
}

1;
