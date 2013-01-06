PhoneNumbers
======================

[libphonenumber](http://code.google.com/p/libphonenumber/) for Perl

Usage
------

    my $parser = PhoneNumbers->new(+{ data_dir => '/path/to/data_dir' });
    my $parsed = $parser->parse('+819012345678);
    print Dumper $parsed;

    # {
    #       'is_valid' => 1,
    #       'region_code' => 'JP',
    #       'national_number' => '09012345678',
    #       'e164_number' => '+819012345678',
    #       'number_type' => 'mobile',
    #}

More Infomation
------
[http://code.google.com/p/libphonenumber/](http://code.google.com/p/libphonenumber/)

[http://d.hatena.ne.jp/i110/20130106/1357484055](http://d.hatena.ne.jp/i110/20130106/1357484055)


