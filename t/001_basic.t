#!perl -w
use strict;
use Test::More;

use PhoneNumbers;
use File::Spec;
use FindBin;

my $DATA_DIR = "$FindBin::Bin/../data";

my $FIXED_LINE           = $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_FIXED_LINE;
my $MOBILE               = $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_MOBILE;
my $FIXED_LINE_OR_MOBILE = $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_FIXED_LINE_OR_MOBILE;
my $TOLL_FREE            = $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_TOLL_FREE;
my $PREMIUM_RATE         = $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_PREMIUM_RATE;
my $SHARED_COST          = $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_SHARED_COST;
my $VOIP                 = $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_VOIP;
my $PERSONAL_NUMBER      = $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_PERSONAL_NUMBER;
my $PAGER                = $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_PAGER;
my $UAN                  = $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_UAN;
my $VOICEMAIL            = $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_VOICEMAIL;
my $UNKNOWN              = $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_UNKNOWN;

my $parser = PhoneNumbers->new(+{
	data_dir => $DATA_DIR,
});

subtest 'JP success cases', sub {
	_test('+819012345678',
		+{
			is_valid        => 1,
			region_code     => 'JP',
			number_type     => $MOBILE,
			national_number => '09012345678',
			e164_number     => '+819012345678',
		}
	);

	_test('+8109012345678',
		+{
			is_valid        => 1,
			region_code     => 'JP',
			number_type     => $MOBILE,
			national_number => '09012345678',
			e164_number     => '+819012345678',
		}
	);

	_test(
		+{
			number => '09012345678',
			default_region => 'JP',
		},
		+{
			is_valid        => 1,
			region_code     => 'JP',
			number_type     => $MOBILE,
			national_number => '09012345678',
			e164_number     => '+819012345678',
		}
	);

	_test('+81312345678',
		+{
			is_valid        => 1,
			region_code     => 'JP',
			number_type     => $FIXED_LINE,
			national_number => '0312345678',
			e164_number     => '+81312345678',
		}
	);
};

subtest 'JP failure cases', sub {
	_test('09012345678', +{ is_valid => 0 });
	_test('+810000000000', +{ is_valid => 0 });
};

subtest 'US', sub  {
	_test('+16502530000',
		+{
			is_valid        => 1,
			region_code     => 'US',
			number_type     => $FIXED_LINE_OR_MOBILE,
			national_number => '6502530000',
			e164_number     => '+16502530000',
		}
	);
};

done_testing;

sub _test {
	my ($number, $expected) = @_;
	local $Test::Builder::Level = $Test::Builder::Level + 2;
	
	eval {
		my $parsed = $parser->parse($number);
		is($parsed->{is_valid}, $expected->{is_valid});
		if ($parsed->{is_valid}) {
			is_deeply($parsed, $expected);
		}
	};
	if ($@) {
		is(0, $expected->{is_valid});
	}
}
