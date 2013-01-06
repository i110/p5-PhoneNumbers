package PhoneNumbers::PhoneNumber;

use strict;
use warnings;
use Carp::Clan;

use Class::Accessor::Lite (
	rw => [qw/
		raw_input
		extension
		country_code_source
		country_code
		preferred_domestic_carrier_code
		italian_leading_zero
		national_number
	/],
);
sub new {
	my ($class, $proto) = @_;
	$proto ||= +{};
	return bless $proto, $class;
}

1;
