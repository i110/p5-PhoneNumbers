package PhoneNumbers::PhoneNumberUtil;

use strict;
use warnings;
use Carp ();
use List::MoreUtils qw(all);
use File::Spec;
use Clone qw(clone);

use PhoneNumbers::Constants;
use PhoneNumbers::PhoneNumber;
use PhoneNumbers::PhoneMetaData;

my $DEFAULT_DATA_PREFIX = 'PhoneNumberMetadataProto';

my $UNKNOWN_REGION                   = 'ZZ';
my $REGION_CODE_FOR_NON_GEO_ENTITY   = '001';
my $NANPA_COUNTRY_CODE               = 1;
my $MAX_INPUT_STRING_LENGTH          = 250;
my $MIN_LENGTH_FOR_NSN               = 2;
my $MAX_LENGTH_FOR_NSN               = 16;
my $MAX_LENGTH_COUNTRY_CODE          = 3;
my $PLUS_SIGN                        = '+';
my $STAR_SIGN                        = '*';
my $PLUS_CHARS                       = "+\x{FF0B}";
my $DIGITS                           = "\\p{Nd}";
my $VALID_ALPHA                      = "a-zA-Z";
my $VALID_ALPHA_PHONE_PATTERN        = "(?:.*?[A-Za-z]){3}.*";
my $CAPTURING_EXTN_DIGITS            = "(" . $DIGITS . "{1,7})";
my $RFC3966_EXTN_PREFIX              = ';ext=';
my $RFC3966_PREFIX                   = 'tel:';
my $RFC3966_PHONE_CONTEXT            = ';phone-context=';
my $RFC3966_ISDN_SUBADDRESS          = ';isub=';
my $NP_PATTERN                       = "\\\$NP";
my $FG_PATTERN                       = "\\\$FG";
my $CC_PATTERN                       = "\\\$CC";
my $FIRST_GROUP_PATTERN              = "(\\\$\\d)";
my $SINGLE_EXTN_SYMBOLS_FOR_MATCHING = "x\x{FF58}#\x{FF03}~\x{FF5E}";
my $SINGLE_EXTN_SYMBOLS_FOR_PARSING  = ',' . $SINGLE_EXTN_SYMBOLS_FOR_MATCHING;
my $EXTN_PATTERNS_FOR_PARSING        =
	PhoneNumbers::PhoneNumberUtil->_create_extn_pattern($SINGLE_EXTN_SYMBOLS_FOR_PARSING);
my $EXTN_PATTERN                     = "(?:$EXTN_PATTERNS_FOR_PARSING)\$";
my $UNWANTED_END_CHARS               = "[[\\P{N}&&\\P{L}]&&[^#]]+\$";
my $SECOND_NUMBER_START              = "[\\\\/] *x";
my $VALID_PUNCTUATION = "-x\x{2010}-\x{2015}\x{2212}\x{30FC}\x{FF0D}-\x{FF0F} \x{00A0}\x{00AD}\x{200B}\x{2060}\x{3000}()\x{FF08}\x{FF09}\x{FF3B}\x{FF3D}.\\[\\]/~\x{2053}\x{223C}\x{FF5E}";
my $VALID_PHONE_NUMBER = join('',
	"(?:",
	$DIGITS,
	"{", $MIN_LENGTH_FOR_NSN, "}",
	"|",
	"[", $PLUS_CHARS, "]*",
	"(?:[", $VALID_PUNCTUATION, $STAR_SIGN, "]*", $DIGITS, "){3,}",
	"[", $VALID_PUNCTUATION, $STAR_SIGN, $VALID_ALPHA, $DIGITS, "]*",
	")",
); 
my $SEPARATOR_PATTERN = "[$VALID_PUNCTUATION]+";
my $DEFAULT_EXTN_PREFIX = " ext. ";


my $instance = undef;

sub new {
	my ($class, $args) = @_;
	$args ||= +{};

	my $data_dir    = $args->{data_dir}    or Carp::croak 'data_dir is missing';
	my $data_prefix = $args->{data_prefix} || $DEFAULT_DATA_PREFIX;
	my $data_format = 'json';

	return bless +{
		country_calling_code_to_region_code_map => 
			\%PhoneNumbers::Constants::COUNTRY_CODE_TO_REGION_CODE_MAP,
		country_codes_for_non_geographical_region => +{},
		country_code_to_non_geographical_metadata_map => +{},
		supported_regions => +{},
		nanpa_regions => +{},
		region_to_metadata_map => +{},

		data_dir    => $data_dir,
		data_prefix => $data_prefix,
		data_format => $data_format,

		%$args,
	}, $class;
}

sub get_instance {
	my ($class, $args) = @_;

	unless (defined($instance)) {
		$instance = PhoneNumbers::PhoneNumberUtil->new($args);
		$instance->_init;
	}
	return $instance;
}

sub _init {
	my ($self) = @_;

	for my $country_code (keys %{ $self->{country_calling_code_to_region_code_map} }) {
		my $region_codes = $self->{country_calling_code_to_region_code_map}->{$country_code};

		if (scalar(@$region_codes) == 1 && $REGION_CODE_FOR_NON_GEO_ENTITY eq $region_codes->[0]) {
			$self->{country_codes_for_non_geographical_region}->{$country_code} = 1;
		} else {
			$self->{supported_regions}->{$_} = 1 for @$region_codes;
		}
	}

	if ($self->{supported_regions}->{$REGION_CODE_FOR_NON_GEO_ENTITY}) {
		delete $self->{supported_regions}->{$REGION_CODE_FOR_NON_GEO_ENTITY};
		Carp::carp "invalid metadata (country calling code was mapped to the non-geo entity as well as specific region(s))";
	}
	
	if (my $nanpa_region = $self->{country_calling_code_to_region_code_map}->{$NANPA_COUNTRY_CODE}) {
		$self->{nanpa_regions}->{$nanpa_region} = 1;
	}
}

sub parse {
	my ($self, $args) = @_;
	my $number_to_parse = $args->{number_to_parse} || Carp::croak "NOT_A_NUMBER\tThe phone number supplied was null.";
	my $default_region = $args->{default_region};
	my $keep_raw_input = $args->{keep_raw_input} || 0;
	my $check_region = defined($args->{check_region}) ? $args->{check_region} : 1;
	my $phone_number = $args->{phone_number}; 


	unless (defined($phone_number)) {
		$phone_number = PhoneNumbers::PhoneNumber->new;
	}
	
	if (length($number_to_parse) > $MAX_INPUT_STRING_LENGTH) {
		Carp::croak "TOO_LONG\tThe string supplied was too long to parse.";
	}

	my $national_number = $self->_national_number_for_parsing($number_to_parse);

# use Test::More; diag explain $national_number;
	unless ($self->_is_viable_phone_number($national_number)) {
		Carp::croak "NOT_A_NUMBER\tThe string supplied did not seem to be a phone number.";
	}

	if ($check_region && ! $self->_check_region_for_parsing($national_number, $default_region)) {
		Carp::croak "INVALID_COUNTRY_CODE\tMissing or invalid default region.";
	}

	if ($keep_raw_input) {
		$phone_number->raw_input($number_to_parse);
	}

	my $extension;
	($extension, $national_number) = $self->_maybe_strip_extension($national_number);
	if ($extension) {
		$phone_number->extension($extension);
	}

	my $region_metadata = $self->_get_metadata(+{
		region_code => $default_region,
	});
	

	my $normalized_national_number = '';
	my $country_code = 0;
	eval {
		($country_code, $normalized_national_number) = $self->_maybe_extract_country_code(+{
			number => $national_number,
			default_region_metadata => $region_metadata,
			national_number => $normalized_national_number,
			keep_raw_input => $keep_raw_input,
			phone_number => $phone_number,
		});
	};
	if ($@) {
		if ($@ =~ /INVALID_COUNTRY_CODE/ && $national_number =~ /^[$PLUS_CHARS]+/) {
				my $after = $';
				($country_code, $normalized_national_number) = $self->_maybe_extract_country_code(+{
					number => $after,
					default_region_metadata => $region_metadata,
					national_number => $normalized_national_number,
					keep_raw_input => $keep_raw_input,
					phone_number => $phone_number,
				});
				if ($country_code == 0) {
					Carp::croak "INVALID_COUNTRY_CODE\tCould not interpret numbers after plus-sign.";
				}
		} else {
			Carp::croak $@;
		}
	}

	if ($country_code != 0) {
		my $phone_number_region = $self->get_region_code_for_country_code($country_code);
		if ($phone_number_region ne ($default_region || '')) {
			$region_metadata = $self->_get_metadata(+{
				region_code => $phone_number_region,
				country_calling_code => $country_code,
			});
		}

	} else {
		$national_number = $self->_normalize($national_number);
		$normalized_national_number .= $national_number;
		if (defined($default_region)) {
			$country_code = $region_metadata->{country_code};
			$phone_number->country_code($country_code);
		} elsif ($keep_raw_input) {
			$phone_number->country_code_source(undef);
		}
	}

	if (length($normalized_national_number) < $MIN_LENGTH_FOR_NSN) {
		Carp::croak "TOO_SHORT_NSN\tThe string supplied is too short to be a phone number.";
	}

	if (defined($region_metadata)) {
		my $carrier_code = '';
		(undef, $normalized_national_number, $carrier_code) =
			$self->_maybe_strip_national_prefix_and_carrier_code(
				$normalized_national_number, $region_metadata, $carrier_code);
		if ($keep_raw_input) {
			$phone_number->preferred_domestic_carrier_code($carrier_code);
		}
	}


	if (length($normalized_national_number) < $MIN_LENGTH_FOR_NSN) {
		Carp::croak "TOO_SHORT_NSN\tThe string supplied is too short to be a phone number.";
	}
	if (length($normalized_national_number) > $MAX_LENGTH_FOR_NSN) {
		Carp::croak "TOO_LONG\tThe string supplied is too long to be a phone number.";
	}

	if ($normalized_national_number =~ /^0/) {
		$phone_number->italian_leading_zero(1);
	}

	$phone_number->national_number($normalized_national_number);

	return $phone_number;
}

sub _national_number_for_parsing {
	my ($self, $number_to_parse) = @_;

	my $national_number = '';

	my $index_of_phone_context = index($number_to_parse, $RFC3966_PHONE_CONTEXT);
	if ($index_of_phone_context > 0) {
		my $phone_context_start = $index_of_phone_context + length($RFC3966_PHONE_CONTEXT);
		if (substr($number_to_parse, $phone_context_start, 1) eq $PLUS_SIGN) {
			my $phone_context_end = index($number_to_parse, ';', $phone_context_start);
			if ($phone_context_end > 0) {
				$national_number .= substr($number_to_parse, $phone_context_start, $phone_context_end - $phone_context_start);
			} else {
				$national_number .= substr($number_to_parse, $phone_context_start);
			}
		}

		my $tel_start = index($number_to_parse, $RFC3966_PREFIX) + length($RFC3966_PREFIX);
		$national_number .= substr($number_to_parse, $tel_start, $index_of_phone_context - $tel_start);
	} else {
		$national_number .= $self->_extract_possible_number($number_to_parse);
	}

	$national_number =~ s/$RFC3966_ISDN_SUBADDRESS.+$//;

	return $national_number;
}

sub _extract_possible_number {
	my ($self, $number) = @_;
	if ($number =~ /([$PLUS_CHARS$DIGITS].*)$/) {
		$number = $1;
		if ($number =~ /$UNWANTED_END_CHARS/) {
			$number = $`;
		}
		if ($number =~ /$SECOND_NUMBER_START/) {
			$number = $`;
		}
		return $number;
	} else {
		return '';
	}
}

sub _is_viable_phone_number {
	my ($class, $number) = @_;
	if (length($number) < $MIN_LENGTH_FOR_NSN) {
		return 0;
	}

	if ($number =~ /^$VALID_PHONE_NUMBER(?:$EXTN_PATTERNS_FOR_PARSING)?$/i) {
		return 1;
	} else {
		return 0;
	}
}

sub _create_extn_pattern {
	my ($class, $single_extn_symbols) = @_;
	
	return join('', $RFC3966_EXTN_PREFIX,
			$CAPTURING_EXTN_DIGITS,
			"|",
			"[ \x{00A0}\\t,]*",
			"(?:e?xt(?:ensi(?:o\x{0301}?|\x{00F3}))?n?|\x{FF45}?\x{FF58}\x{FF54}\x{FF4E}?|",
			"[", $single_extn_symbols, "]|int|anexo|\x{FF49}\x{FF4E}\x{FF54})",
			"[:\\.\x{FF0E}]?[ \x{00A0}\\t,-]*", $CAPTURING_EXTN_DIGITS,
			"#?|", "[- ]+(", $DIGITS, "{1,5})#");
}

sub _check_region_for_parsing {
	my ($self, $number_to_parse, $default_region) = @_;
	
	unless ($self->_is_valid_region_code($default_region)) {
		unless ($number_to_parse && $number_to_parse =~ /^[$PLUS_CHARS]+/) {
			return 0;
		}
	}
	return 1;
}

sub _is_valid_region_code {
	my ($self, $region_code) = @_;
	return defined($region_code) && $self->{supported_regions}->{$region_code};
}

sub _maybe_strip_extension {
	my ($self, $number) = @_;

	# NOTICE: unicode case insensitiveness is not working in perl 5.8
	if ((my @captures = $number =~ /$EXTN_PATTERN/i) && ($self->is_viable_phone_number($`))) {
		for my $capture (@captures) {
			if ($capture) {
				return ($capture, $');
			}
		}
	}

	return ('', $number);
}

sub _get_metadata {
	my ($self, $args) = @_;
	my $rc  = $args->{region_code};
	my $ccc = $args->{country_calling_code};

	if (!$rc && !$ccc) {
		return undef;
	}

	my $region_mode = 1;
	# $rc and $ccc are exlusive
	if ($REGION_CODE_FOR_NON_GEO_ENTITY eq $rc) {
		$region_mode = 0;
	}

	if ($region_mode) {
		unless ($self->_is_valid_region_code($rc)) {
			return undef;
		}
		if ($self->{region_to_metadata_map}->{$rc}) {
			return $self->{region_to_metadata_map}->{$rc};
		}
	} else {
		unless ($self->{country_calling_code_to_region_code_map}->{$ccc}) {
			return undef;
		}
		if ($self->{country_code_to_non_geographical_metadata_map}->{$ccc}) {
			return $self->{country_code_to_non_geographical_metadata_map}->{$ccc};
		}
	}

	my $file_name = sprintf(
		'%s_%s.%s',
		$self->{data_prefix},
		($region_mode ? $rc : $ccc),
		$self->{data_format},
	);
	my $file_path = File::Spec->catfile($self->{data_dir}, $file_name);

	my $metadata = PhoneNumbers::PhoneMetaData->read_from_file(+{
		file_path => $file_path,
	});

	if ($region_mode) {
		$self->{region_to_metadata_map}->{$rc} = $metadata;
	} else {
		$self->{country_code_to_non_geographical_metadata_map}->{$ccc} = $metadata;
	}

	return $metadata;
}

# sub _get_metadata_for_non_geographical_region {
# 	my ($self, $country_calling_code) = @_;
# 
# 	unless ($self->{country_calling_code_to_region_code_map}->{$country_calling_code}) {
# 		$self->_load_metadata_from_file($self->{current_file_prefix}, $REGION_CODE_FOR_NON_GEO_ENTITY, $country_calling_code);
# 	}
# 
# 	return $self->{country_calling_code_to_region_code_map}->{$country_calling_code};
# }
# 
# sub _load_metadata_from_file {
# 	my ($self, $file_prefix, $region_code, $country_calling_code) = @_;
# 
# }

# return ($country_code, $national_number);
sub _maybe_extract_country_code {
	my ($self, $args) = @_;
	my $number                  = $args->{number};
	my $default_region_metadata = $args->{default_region_metadata};
	my $national_number         = $args->{national_number};
	my $keep_raw_input          = $args->{keep_raw_input};
	my $phone_number            = $args->{phone_number};

	unless ($number) {
		return (0, $national_number);
	}

	my $possible_country_idd_prefix = "NonMatch";
	if ($default_region_metadata) {
		$possible_country_idd_prefix = $default_region_metadata->{international_prefix};
	}
	
	my ($full_number, $country_code_source) = 
		$self->_maybe_strip_international_prefix_and_normalize($number, $possible_country_idd_prefix);
	if ($keep_raw_input) {
		$phone_number->country_code_source($country_code_source);
	}

	if ($country_code_source != $PhoneNumbers::Constants::COUNTRY_CODE_SOURCE_FROM_DEFAULT_COUNTRY) {

		if (length($full_number) <= $MIN_LENGTH_FOR_NSN) {
			Carp::croak "TOO_SHORT_AFTER_IDD\tPhone number had an IDD, but after this was not long enough to be a viable phone number.";
		}

		(my $potential_country_code, $national_number) = $self->_extract_country_code($full_number, $national_number);
		if ($potential_country_code != 0) {
			$phone_number->country_code($potential_country_code);
			return ($potential_country_code, $national_number);
		} else {
			Carp::croak "INVALID_COUNTRY_CODE\tCountry calling code supplied was not recognised.";
		}
		
	} elsif (defined($default_region_metadata)) {
		my $default_country_code = $default_region_metadata->{country_code};
		if ($full_number =~ /^$default_country_code/) {
			my $potential_national_number = $';
			
			(undef, $potential_national_number, undef) =
				$self->_maybe_strip_national_prefix_and_carrier_code(
					$potential_national_number, $default_region_metadata, undef);

			my $general_desc = $default_region_metadata->{general_desc};
			my $valid_number_pattern    = $general_desc->{national_number_pattern};
			my $possible_number_pattern = $general_desc->{possible_number_pattern};

			if (
					(
						$full_number               !~ /^$valid_number_pattern$/ && 
						$potential_national_number =~ /^$valid_number_pattern$/
					) ||
					(
						$self->_test_number_length_against_pattern($possible_number_pattern, $full_number)
							== $PhoneNumbers::Constants::VALIDATION_RESULT_TOO_LONG
					)
			) {
				$national_number .= $potential_national_number;
				if ($keep_raw_input) {
					$phone_number->country_code_source($PhoneNumbers::Constants::COUNTRY_CODE_SOURCE_FROM_NUMBER_WITHOUT_PLUS_SIGN);
				}
				$phone_number->country_code($default_country_code);
				return ($default_country_code, $national_number);
			}
		}
	}

	$phone_number->country_code(0);
	return (0, $national_number);
}

# this method may modify $number and return that
sub _maybe_strip_international_prefix_and_normalize {
	my ($self, $number, $possible_idd_prefix) = @_;

	unless ($number) {
		return ($number, $PhoneNumbers::Constants::COUNTRY_CODE_SOURCE_FROM_DEFAULT_COUNTRY);
	}

	if ($number =~ /^[$PLUS_CHARS]+/) {
		$number = $';

		$number = $self->_normalize($number);
		return ($number, $PhoneNumbers::Constants::COUNTRY_CODE_SOURCE_FROM_NUMBER_WITH_PLUS_SIGN);
	}

	$number = $self->_normalize($number);
	($number, my $parse_success) = $self->_parse_prefix_as_idd($possible_idd_prefix, $number);
	if ($parse_success) {
		return ($number, $PhoneNumbers::Constants::COUNTRY_CODE_SOURCE_FROM_NUMBER_WITH_IDD);
	} else {
		return ($number, $PhoneNumbers::Constants::COUNTRY_CODE_SOURCE_FROM_DEFAULT_COUNTRY);
	}
}

# this method may modify $number and return that
sub _parse_prefix_as_idd {
	my ($self, $pattern, $number) = @_;
	if ($number =~ /^$pattern/) {
		my $after = $';
		if ($after =~ /($DIGITS)/) {
			my $normalized_digit = $self->_normalize_digits($_);
			if ($normalized_digit eq '0') {
				return ($number, 0);
			}
		}
		return ($after, 1);
	}
	return ($number, 0);
}

sub _normalize {
	my ($class, $number) = @_;

	if ($number =~ /^$VALID_ALPHA_PHONE_PATTERN$/) {
		return $class->_normalize_helper(
			$number,
			\%PhoneNumbers::Constants::ALPHA_PHONE_MAPPINGS,
			1,
		);
	} else {
		return $class->_normalize_digits($number);
	}
}

# this is an alias of _normalize_digits
sub normalize_digits_only {
	my ($class, $number) = @_;
	return $class->_normalize_digits($number);
}

# NOTICE: only do FULLWIDTH_DIGIT normalization
sub _normalize_digits {
	my ($class, $number) = @_;
	$number =~ tr/\x{FF10}-\x{FF19}/0123456789/;
	$number =~ s/[^\d]//g;
	return $number;
}

# this method may modify $national_number and return
sub _extract_country_code {
	my ($self, $full_number, $national_number) = @_;
	if (length($full_number) == 0 || $full_number =~ /^0/) {
		return (0, $national_number);
	}

	for (my $i = 1; $i <= $MAX_LENGTH_COUNTRY_CODE && $i <= length($full_number); $i++) {
		my $potential_country_code = int(substr($full_number, 0, $i));
		if ($self->{country_calling_code_to_region_code_map}->{$potential_country_code}) {
			$national_number .= substr($full_number, $i);
			return ($potential_country_code, $national_number);
		}
	}
	return (0, $national_number);
}

# returns ($success, $number, $carrier_code)
sub _maybe_strip_national_prefix_and_carrier_code {
	my ($self, $number, $metadata, $carrier_code) = @_;

	my $possible_national_prefix = $metadata->{national_prefix_for_parsing};
	if (length($number) == 0 || length($possible_national_prefix) == 0) {
		return (0, $number, $carrier_code);
	}

	if (my @captures = ($number =~ /^$possible_national_prefix/)) {
		my $after = $';
		my $num_of_groups = scalar(@-) - 1;
		my $group_captured = ($num_of_groups > 0 && all { $_ } @captures);

		my $national_number_rule = $metadata->{general_desc}->{national_number_pattern};
		my $is_viable_original_number = ($number =~ /^$national_number_rule$/ ? 1 : 0);

		my $transform_rule = $metadata->{national_prefix_transform_rule};
		if (! $transform_rule  || ! $group_captured) {

			if ($is_viable_original_number && $after !~ /^$national_number_rule$/) {
				return (0, $number, $carrier_code);
			}

			if (defined($carrier_code) && $group_captured) {
				$carrier_code .= $captures[0];
			}

			$number = $after;
			return (1, $number, $carrier_code);

		} else {
			my $transformed_number = $number;
			$transformed_number =~ s/^$possible_national_prefix/$transform_rule/;

			if ($is_viable_original_number && $transformed_number !~ /^$national_number_rule$/) {
				return (0, $number, $carrier_code);
			}

			if (defined($carrier_code) && $group_captured) {
				$carrier_code .= $captures[0];
			}
			
			return (1, $transformed_number, $carrier_code);
		}
	}

	return (0, $number, $carrier_code);
}

sub _test_number_length_against_pattern {
	my ($self, $number_pattern, $number) = @_;

	if ($number =~ /^$number_pattern$/) {
		return $PhoneNumbers::Constants::VALIDATION_RESULT_IS_POSSIBLE;
	}
	if ($number =~ /^$number_pattern/) {
		return $PhoneNumbers::Constants::VALIDATION_RESULT_TOO_LONG;
	} else {
		return $PhoneNumbers::Constants::VALIDATION_RESULT_TOO_SHORT;
	}
}

sub get_region_code_for_country_code {
	my ($self, $country_calling_code) = @_;
	my $region_codes = $self->{country_calling_code_to_region_code_map}->{$country_calling_code};
	return defined($region_codes) ? $region_codes->[0] : $UNKNOWN_REGION;
}

sub get_region_code_for_number {
	my ($self, $phone_number) = @_;

	my $country_code = $phone_number->country_code;
	my $national_number = $self->get_national_significant_number($phone_number);
	my $regions = $self->{country_calling_code_to_region_code_map}->{$country_code};

	unless (defined($regions)) {
		Carp::carp "Missing/invalid country_code ($country_code) for number $national_number";
		return undef;
	}

	if (scalar(@$regions) == 1) {
		return $regions->[0];
	} else {
		for my $region (@$regions) {
			my $metadata = $self->_get_metadata(+{ region_code => $region });
			my $leading_digits = $metadata->{leading_digits};
			if ($leading_digits) {
				if ($national_number =~ /^$leading_digits/) {
					return $region;
				}

			} elsif ($self->_get_number_type_helper($national_number, $metadata) ne 
				$PhoneNumbers::Constants::PHONE_NUMBER_TYPE_UNKNOWN) {

				return $region;
			}
		}
	}
}

sub get_national_significant_number {
	my ($self, $phone_number) = @_;
	
	my $national_number = ($phone_number->italian_leading_zero ? '0' : '');
	$national_number .= $phone_number->national_number;
	return $national_number;
}

sub get_number_type {
	my ($self, $phone_number) = @_;

	my $region_code = $self->get_region_code_for_number($phone_number);
	my $metadata = $self->_get_metadata(+{ region_code => $region_code });
	unless (defined($metadata)) {
		return $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_UNKNOWN;
	}

	my $national_significant_number = $self->get_national_significant_number($phone_number);
	return $self->_get_number_type_helper($national_significant_number, $metadata);
}

sub _get_number_type_helper {
	my ($self, $national_number, $metadata) = @_;

	if (! $metadata->{general_desc}->{national_number_pattern} || 
		! $self->_is_number_matching_desc($national_number, $metadata->{general_desc})) {

		return $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_UNKNOWN;
	}

	if ($self->_is_number_matching_desc($national_number, $metadata->{premium_rate})) {
		return $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_PREMIUM_RATE;
	}
	if ($self->_is_number_matching_desc($national_number, $metadata->{toll_free})) {
		return $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_TOLL_FREE;
	}
	if ($self->_is_number_matching_desc($national_number, $metadata->{shared_cost})) {
		return $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_SHARED_COST;
	}
	if ($self->_is_number_matching_desc($national_number, $metadata->{voip})) {
		return $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_VOIP;
	}
	if ($self->_is_number_matching_desc($national_number, $metadata->{personal_number})) {
		return $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_PERSONAL_NUMBER;
	}
	if ($self->_is_number_matching_desc($national_number, $metadata->{pager})) {
		return $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_PAGER;
	}
	if ($self->_is_number_matching_desc($national_number, $metadata->{uan})) {
		return $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_UAN;
	}
	if ($self->_is_number_matching_desc($national_number, $metadata->{voicemail})) {
		return $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_VOICEMAIL;
	}
	if ($self->_is_number_matching_desc($national_number, $metadata->{fixed_line})) {
		if ($metadata->{same_mobile_and_fixed_line_pattern}) {
			return $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_FIXED_LINE_OR_MOBILE;
		} elsif ($self->_is_number_matching_desc($national_number, $metadata->{mobile})) {
			return $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_FIXED_LINE_OR_MOBILE;
		} else {
			return $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_FIXED_LINE;
		}
	}

	if (! $metadata->{same_mobile_and_fixed_line_pattern} && 
		$self->_is_number_matching_desc($national_number, $metadata->{mobile})) {

		return $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_MOBILE;
	}

	return $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_UNKNOWN;

}

sub _is_number_matching_desc {
	my ($self, $national_number, $number_desc) = @_;

	return 0 if $national_number !~ /^$number_desc->{possible_number_pattern}$/;
	return 0 if $national_number !~ /^$number_desc->{national_number_pattern}$/;
	return 1;
}

sub _get_country_code_for_valid_region {
	my ($self, $region_code) = @_;
	my $metadata = $self->_get_metadata(+{ region_code => $region_code });
	unless (defined($metadata)) {
		Carp::croak "Invalid region code: $region_code";
	}

	return $metadata->{country_code};
}

sub is_valid_number {
	my ($self, $phone_number) = @_;
	my $region_code = $self->get_region_code_for_number($phone_number);
	return $self->is_valid_number_for_region($phone_number, $region_code);
}

sub is_valid_number_for_region {
	my ($self, $phone_number, $region_code) = @_;

	my $country_code = $phone_number->country_code;
	my $metadata = $self->_get_metadata(+{
		region_code => $region_code,
		country_calling_code => $country_code,
	});
	if (! defined($metadata) ||
		(
			$region_code ne $REGION_CODE_FOR_NON_GEO_ENTITY &&
			$country_code != $self->_get_country_code_for_valid_region($region_code)
		)
	) {
		return 0;
	}

	my $national_significant_number = $self->get_national_significant_number($phone_number);
	unless ($metadata->{general_desc}->{national_number_pattern}) {
		my $len = length($national_significant_number);
		return $MIN_LENGTH_FOR_NSN < $len && $len <= $MAX_LENGTH_FOR_NSN;
	}

	my $number_type = $self->_get_number_type_helper($national_significant_number, $metadata);
	return $number_type eq $PhoneNumbers::Constants::PHONE_NUMBER_TYPE_UNKNOWN ? 0 : 1;
}

sub format {
	my ($self, $phone_number, $number_format) = @_;

	my $formatted_number = '';

	my $country_calling_code = $phone_number->country_code;
	my $national_significant_number = $self->get_national_significant_number($phone_number);

	if ($number_format == $PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_E164) {
		$formatted_number .= $national_significant_number;
		$formatted_number = $self->_prefix_number_with_country_calling_code($country_calling_code, $number_format, $formatted_number);
		return $formatted_number;
	}

	unless ($self->_has_valid_country_calling_code($country_calling_code)) {
		$formatted_number .= $national_significant_number;
		return $formatted_number;
	}

	my $region_code = $self->get_region_code_for_country_code($country_calling_code);
	my $metadata = $self->_get_metadata(+{ region_code => $region_code });
	$formatted_number .= $self->_format_nsn($national_significant_number, $metadata, $number_format);
	$formatted_number = $self->_maybe_append_formatted_extension($phone_number, $metadata,
		$PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_NATIONAL, $formatted_number);
	$formatted_number = $self->_prefix_number_with_country_calling_code($country_calling_code,
		$PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_NATIONAL, $formatted_number);

	return $formatted_number;
}

sub _prefix_number_with_country_calling_code {
	my ($self, $country_calling_code, $number_format, $formatted_number) = @_;

	if ($number_format eq $PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_E164) {
		$formatted_number = join('', $PLUS_SIGN, $country_calling_code, $formatted_number);
		return $formatted_number;

	} elsif ($number_format eq $PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_INTERNATIONAL) {
		$formatted_number = join('', $PLUS_SIGN, $country_calling_code, ' ', $formatted_number);
		return $formatted_number;

	} elsif ($number_format eq $PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_RFC3966) {
		$formatted_number = join('', $RFC3966_PREFIX, $PLUS_SIGN, $country_calling_code, '-', $formatted_number);
		return $formatted_number;

	} else {
		return $formatted_number;
	}
}

sub _has_valid_country_calling_code {
	my ($self, $country_calling_code) = @_;
	return $self->{country_calling_code_to_region_code_map}->{$country_calling_code};
}

sub _format_nsn {
	my ($self, $number, $metadata, $number_format, $carrier_code) = @_;

	my $intl_number_formats = $metadata->{intl_number_formats};
	my $available_formats =
		(
			scalar(@{ $metadata->{intl_number_formats} }) == 0 ||
			$number_format == $PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_NATIONAL
		) ? $metadata->{number_formats} : $metadata->{intl_number_formats};

	my $formatting_pattern = $self->_choose_formatting_pattern_for_number($available_formats, $number);
	if (defined($formatting_pattern)) {
		return $self->_format_nsn_using_pattern($number, $formatting_pattern, $number_format, $carrier_code);
	} else {
		return $number;
	}
}

sub _choose_formatting_pattern_for_number {
	my ($self, $available_formats, $national_number) = @_;

	for my $number_format (@$available_formats) {
		my $size = scalar(@{ $number_format->{leading_digit_patterns} });
		my $last_pattern = $number_format->{leading_digit_patterns}->[$size - 1];
		if ($size == 0 || $national_number =~ /^$last_pattern/) {
			if ($national_number =~ /^$number_format->{pattern}$/) {
				return $number_format;
			}
		}
	}

	return undef;
}

sub _format_nsn_using_pattern {
	my ($self, $national_number, $formatting_pattern, $number_format, $carrier_code) = @_;
	
	my $formatted_national_number = $national_number;
	my $number_format_rule = $formatting_pattern->{format};
	
	if ($number_format == $PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_NATIONAL &&
		$carrier_code &&
		$formatting_pattern->{domestic_carrier_code_formatting_rule}) {

		my $carrier_code_formatting_rule = $formatting_pattern->{domestic_carrier_code_formatting_rule};
		$carrier_code_formatting_rule =~ s/$CC_PATTERN/$carrier_code/;

		$number_format_rule =~ s/$FIRST_GROUP_PATTERN/$carrier_code_formatting_rule/;

	} else {
		my $national_prefix_formatting_rule = $formatting_pattern->{national_prefix_formatting_rule};
		if ($number_format == $PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_NATIONAL &&
			$national_prefix_formatting_rule) {

			$number_format_rule =~ s/$FIRST_GROUP_PATTERN/$national_prefix_formatting_rule/;
		}
	}

	# TODO: sorry for using eval
	# Are there anyone who know how to use backreference keywords($1, $2, etc..) in substitution?
	eval('$formatted_national_number =~ s/$formatting_pattern->{pattern}/' . $number_format_rule . '/g');

	if ($number_format == $PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_RFC3966) {
		$formatted_national_number =~ s/^$SEPARATOR_PATTERN//;
		$formatted_national_number =~ s/$SEPARATOR_PATTERN/-/g;
	}

	return $formatted_national_number;
}

# return $formatted_number
sub _maybe_append_formatted_extension {
	my ($self, $phone_number, $metadata, $number_format, $formatted_number) = @_;

	if ($phone_number->extension) {
		if ($number_format == $PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_RFC3966) {
			$formatted_number .= $RFC3966_EXTN_PREFIX . $phone_number->extension;
		} else {
			if ($metadata->{preferred_extn_prefix}) {
				$formatted_number .= $metadata->{preferred_extn_prefix} . $phone_number->extension;
			} else {
				$formatted_number .= $DEFAULT_EXTN_PREFIX . $phone_number->extension;
			}
		}
	}

	return $formatted_number;
}

sub format_in_original_format {
	my ($self, $phone_number, $region_calling_from) = @_;

	if ($phone_number->raw_input) {
		if ($self->_has_unexpected_italian_leading_zero($phone_number) ||
			! $self->_has_formatting_pattern_for_number($phone_number)
		) {
			return $phone_number->raw_input;
		}
	}

	my $ccs = $phone_number->country_code_source;
	unless ($ccs) {
		return $self->format($phone_number, $PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_NATIONAL);
	}

	my $formatted_number;
	if ($ccs == $PhoneNumbers::Constants::COUNTRY_CODE_SOURCE_FROM_NUMBER_WITH_PLUS_SIGN) {
		$formatted_number =
			$self->format($phone_number, $PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_INTERNATIONAL);

	} elsif ($ccs == $PhoneNumbers::Constants::COUNTRY_CODE_SOURCE_FROM_NUMBER_WITH_IDD) {
		$formatted_number =
			$self->format_out_of_country_calling_number($phone_number, $region_calling_from);

	} elsif ($ccs == $PhoneNumbers::Constants::COUNTRY_CODE_SOURCE_FROM_NUMBER_WITHOUT_PLUS_SIGN) {
		$formatted_number =
			$self->format($phone_number, $PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_INTERNATIONAL);
		$formatted_number = substr($formatted_number, 1);

	} else { # FROM_DEFAULT_COUNTRY and others

		my $region_code = $self->get_region_code_for_country_code($phone_number->country_code);
		my $national_prefix = $self->get_ndd_prefix_for_region($region_code, 1);
		my $national_format = $self->format($phone_number, $PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_NATIONAL);

		if (! $national_prefix) {
			$formatted_number = $national_format;
			goto BREAKED;

		}

		if ($self->_raw_input_contains_national_prefix($phone_number->raw_input, $national_prefix, $region_code)) {
			$formatted_number = $national_format;
			goto BREAKED;
		
		}

		my $metadata = $self->_get_metadata(+{ region_code => $region_code });
		my $national_number = $self->get_national_significant_number($phone_number);
		my $format_rule = $self->choose_formatting_pattern_for_number($metadata->{number_formats}, $national_number);

		unless ($format_rule) {
			$formatted_number = $national_format;
			goto BREAKED;
		}
		
		my $candidate_national_prefix_rule = $format_rule->{national_prefix_formatting_rule};
		my $index_of_first_group = index($candidate_national_prefix_rule, '$1');

		if ($index_of_first_group <= 0) {
			$formatted_number = $national_format;
			goto BREAKED;
		}

		$candidate_national_prefix_rule = substr($candidate_national_prefix_rule, $index_of_first_group);
		$candidate_national_prefix_rule = $self->_normalize_digits($candidate_national_prefix_rule);

		unless ($candidate_national_prefix_rule) {
			$formatted_number = $national_format;
			goto BREAKED;
		}

		my $number_format_copy = Clone::clone($format_rule);
		$number_format_copy->{national_prefix_formatting_rule} = '';
		$formatted_number =
			$self->format_by_pattern(
				$phone_number,
				$PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_NATIONAL,
				[ $number_format_copy ]
			);
	}

BREAKED:

	my $raw_input = $phone_number->raw_input;
	if ($formatted_number && $raw_input) {
		my $normalized_formatted_number =
			$self->_normalize_helper($formatted_number, $PhoneNumbers::Constants::DIALLABLE_CHAR_MAPPINGS, 1);
		my $normalized_raw_input =
			$self->_normalize_helper($raw_input, $PhoneNumbers::Constants::DIALLABLE_CHAR_MAPPINGS, 1);
		if ($normalized_formatted_number ne $normalized_raw_input) {
			$formatted_number = $raw_input;
		}
	}

	return $formatted_number;
}

sub _normalize_helper {
	my ($self, $number, $normalization_replacements, $remove_non_matches) = @_;

	my $normalized_number = join('', map {
		$normalization_replacements->{uc($_)} || ($remove_non_matches ? '' : $_)
	} split('', $number));

	return $normalized_number;
}

sub format_by_pattern {
	my ($self, $phone_number, $number_format, $user_defined_formats) = @_;

	my $country_calling_code = $phone_number->country_code;
	my $national_significant_number = $self->get_national_significant_number($phone_number);
	unless ($self->_has_valid_country_calling_code($country_calling_code)) {
		return $national_significant_number;
	}

	my $region_code = $self->_get_region_code_for_country_code($country_calling_code);
	my $metadata = $self->_get_metadata(+{
		country_calling_code => $country_calling_code,
		region_code => $region_code,
	});

	my $formatted_number = '';
	my $formatting_pattern = $self->_choose_formatting_pattern_for_number($user_defined_formats, $national_significant_number);
	
	if (! $formatting_pattern) {
		$formatted_number .= $national_significant_number;
	} else {
		my $number_format_copy = Clone::clone($formatting_pattern);
		my $national_prefix_formatting_rule = $formatting_pattern->{national_prefix_formatting_rule};
		if ($national_prefix_formatting_rule) {
			my $national_prefix = $metadata->{national_prefix};
			if ($national_prefix) {
				$national_prefix_formatting_rule =~ s/$NP_PATTERN/$national_prefix/;
				$national_prefix_formatting_rule =~ s/$FG_PATTERN/\\\$1/;
				$number_format_copy->{national_prefix_formatting_rule} = $national_prefix_formatting_rule;

			} else {
				$number_format_copy->{national_prefix_formatting_rule} = '';
			}
		}

		$formatted_number .= $self->_format_nsn_using_pattern($national_significant_number, $number_format_copy, $number_format);

	}

	$formatted_number = $self->_maybe_append_formatted_extension($phone_number, $metadata,
		$number_format, $formatted_number);
	$formatted_number = $self->_prefix_number_with_country_calling_code($country_calling_code, $number_format, $formatted_number);

	return $formatted_number;
}

# TODO:
sub format_out_of_country_calling_number {
	my ($self, $phone_number, $region_calling_from) = @_;
	Carp::croak "under construction";
}

sub _raw_input_contains_national_prefix {
	my ($self, $raw_input, $national_prefix, $region_code) = @_;

	my $normalized_national_number = $self->_normalize_digits($raw_input);
	if ($normalized_national_number =~ /^$national_prefix/) {
		eval {

			my $parsed = $self->parse(substr($normalized_national_number, length($national_prefix)), $region_code);
			return $self->is_valid_number($parsed);
		};
		if ($@) {
			return 0;
		}
	}

	return 0;
}

sub get_ndd_prefix_for_region {
	my ($self, $region_code, $strip_non_digits) = @_;

	my $metadata = $self->_get_metadata(+{ region_code => $region_code });
	unless (defined($metadata)) {
		Carp::carp "Invalid or missing region code (" . ($region_code || 'null') . ") provided.";
		return undef;
	}

	my $national_prefix = $metadata->{national_prefix};
	unless ($national_prefix) {
		return undef;
	}

	if ($strip_non_digits) {
		$national_prefix =~ s/~//g;
	}

	return $national_prefix;
}

sub _has_unexpected_italian_leading_zero {
	my ($self, $phone_number) = @_;

	return $phone_number->italian_leading_zero && ! $self->_is_leading_zero_possible($phone_number->country_code);
}

sub _is_leading_zero_possible {
	my ($self, $country_calling_code) = @_;

	my $main_metadata_for_calling_code = $self->_get_metadata(+{
		country_calling_code => $country_calling_code,
		region_code => $self->_get_region_code_for_country_code($country_calling_code),
	});
	unless (defined($main_metadata_for_calling_code)) {
		return 0;
	}

	return $main_metadata_for_calling_code->{leading_zero_possible};
}

sub _has_formatting_pattern_for_number {
	my ($self, $phone_number) = @_;

	my $country_calling_code = $phone_number->country_code;
	my $phone_number_region = $self->_get_region_code_for_country_code($country_calling_code);
	my $metadata = $self->_get_metadata(+{
		country_calling_code => $country_calling_code,
		region_code => $phone_number_region,
	});
	unless (defined($metadata)) {
		return 0;
	}

	my $national_number = $self->_get_national_significant_number($phone_number);
	my $format_rule = $self->_choose_formatting_pattern_for_number($metadata->{number_formats}, $national_number);
	return defined($format_rule);
}

1;
