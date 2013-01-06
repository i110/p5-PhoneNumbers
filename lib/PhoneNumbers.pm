package PhoneNumbers;
use 5.008_001;
use strict;
use warnings;
use Carp ();

our $VERSION = '0.01';

use PhoneNumbers::Constants;
use PhoneNumbers::PhoneNumberUtil;

sub new {
	my ($class, $args) = @_;
	$args->{data_dir} or Carp::croak 'data_dir is required';
	return bless $args, $class;
}

sub is_valid_number {
	my ($self, $args) = @_;

	my $parsed;
	eval {
		$parsed = $self->parse($args);
	};
	if ($@) {
		return 0;
	}
	return $parsed->{is_valid};
}

sub parse {
	my ($self, $args) = @_;

	my ($number, $default_region);
	if (ref($args) eq 'HASH') {
		$number         = $args->{number} or Carp::croak 'number is required';
		$default_region = $args->{default_region};
	} else {
		$number = $args;
	}

	my $util = PhoneNumbers::PhoneNumberUtil->get_instance(+{
		data_dir => $self->{data_dir},
	});
	my $phone_number = $util->parse(+{
		number_to_parse => $number,
		default_region  => $default_region,
	});

	my $is_valid = $util->is_valid_number($phone_number);
	my $region_code = $util->get_region_code_for_number($phone_number);
	my $number_type = $util->get_number_type($phone_number);
	my $e164_number = $util->format($phone_number, $PhoneNumbers::Constants::PHONE_NUMBER_FORMAT_E164);
	my $national_number = $util->normalize_digits_only(
		$util->format_in_original_format($phone_number, $region_code)
	);

	return +{
		is_valid        => $is_valid,
		region_code     => $region_code,
		number_type     => $number_type,
		e164_number     => $e164_number,
		national_number => $national_number,
	};
}

1;
__END__

=head1 NAME"

PhoneNumbers - Perl extention to do something

=head1 VERSION

This document describes PhoneNumbers version 0.01.

=head1 SYNOPSIS

    use PhoneNumbers;

=head1 DESCRIPTION

# TODO

=head1 INTERFACE

=head2 Functions

=head3 C<< hello() >>

# TODO

=head1 DEPENDENCIES

Perl 5.8.1 or later.

=head1 BUGS

All complex software has bugs lurking in it, and this module is no
exception. If you find a bug please either email me, or add the bug
to cpan-RT.

=head1 SEE ALSO

L<perl>

=head1 AUTHOR

i110 E<lt>i.nagata110@gmail.comE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2013, i110. All rights reserved.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
