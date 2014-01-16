package vCard::AddressBook;
use Moo;
use vCard;
use Path::Class;
use Carp;
use Text::vCard;
use Text::vCard::Addressbook;

=head1 NAME

vCard::AddressBook - read, write, and edit a multiple vCards

=head1 SYNOPSIS

    use vCard::AddressBook;

    # create the object
    my $address_book = vCard::AddressBook->new();

    $address_book->load_file('/path/file.vcf');
    $address_book->load_string($string);

    my $vcard = $adress_book->add_vcard; # returns a vCard object
    $vcard->fullname('Bruce Banner, PhD');
    $vcard->email_addresses([
        { type => ['work'], address => 'bbanner@ssh.secret.army.mil' },
        { type => ['home'], address => 'bbanner@timewarner.com'      },
    ]);

    # $address_book->vcards() returns a L<vCard> object
    foreach my $vcard ( $address_book->vcards() ) {
        print $vcard->fullname() . "\n";
        print $vcard->email_addresses->[0]->{address} . "\n";
    }

    my $file   = $address_book->as_file('/path/file.vcf'); # write to a file
    my $string = $address_book->as_string();


=head1 DESCRIPTION

A vCard is a digital business card.  L<vCard> and vCard::AddressBook provide an
API for parsing, editing, and creating vCards.

This module is built on top of L<Text::vCard> and provides a more intuitive user
interface.  


=head1 ENCODING AND UTF-8

=head2 Constructor Arguments

The 'encoding_in' and 'encoding_out' constructor parameters allow you to read
and write vCard files with any encoding.  Examples of valid values are
'UTF-8', 'Latin1', and 'none'.  

Both parameters default to 'UTF-8' and this should just work for the vast
majority of people.  The latest vCard RFC 6350 only allows UTF-8 as an encoding
so most people should not need to use either parameter. 

=head2 MIME encodings

vCard RFC 6350 only allows UTF-8 but it still permits 8bit MIME encoding
schemes such as Quoted-Printable and Base64 which are supported by this module.

=head2 Manually setting values on a vCard object

If you manually set values on a vCard object they must be decoded values.  The
only exception to this rule is if you are messing around with the
'encoding_out' constructor arg.


=head1 METHODS

=cut

has encoding_in  => ( is => 'rw', default => sub {'UTF-8'} );
has encoding_out => ( is => 'rw', default => sub {'UTF-8'} );
has vcards       => ( is => 'rw', default => sub { [] } );

=head2 add_vcard()

Creates a new vCard object and adds it to the address book.  Returns a L<vCard>
object.

=cut

sub add_vcard {
    my ($self) = @_;
    my $vcard = vCard->new(
        {   encoding_in  => $self->encoding_in,
            encoding_out => $self->encoding_out,
        }
    );
    push @{ $self->vcards }, $vcard;
    return $vcard;
}

=head2 load_file($filename)

Load and parse the contents of $filename.  Returns $self so the method can be
chained.

=cut

sub load_file {
    my ( $self, $filename ) = @_;

    my $file = ref $filename eq 'Path::Class::File'    #
        ? $filename
        : file($filename);

    my @iomode = $self->encoding_in eq 'none'          #
        ? ()
        : ( iomode => '<:encoding(' . $self->encoding_in . ')' );

    $self->load_string( scalar $file->slurp(@iomode) );

    return $self;
}

sub _slurp {
    my ($self) = @_;
}

=head2 load_string($string)

Load and parse the contents of $string.  This method assumes that $string is
decoded (but not MIME decoded).  Returns $self so the method can be chained.

=cut

sub load_string {
    my ( $self, $string ) = @_;
    $self->_create_vcards($string);
    return $self;
}

sub _create_vcards {
    my ( $self, $string ) = @_;

    my $vcards_data = Text::vCard::Addressbook->new(
        {   encoding_in  => $self->encoding_in,
            encoding_out => $self->encoding_out,
        }
    )->_pre_process_text($string);

    foreach my $vcard_data (@$vcards_data) {
        carp "This file has $vcard_data->{type} data that was not parsed"
            unless $vcard_data->{type} =~ /VCARD/i;

        my $vcard = vCard->new(
            {   encoding_in  => $self->encoding_in,
                encoding_out => $self->encoding_out,
            }
        );
        my $text_vcard = Text::vCard->new(
            {   asData_node  => $vcard_data->{properties},
                encoding_out => $self->encoding_out,
            }
        );

        $self->_copy_simple_nodes( $text_vcard => $vcard );
        $self->_copy_phones( $text_vcard => $vcard );
        $self->_copy_addresses( $text_vcard => $vcard );
        $self->_copy_email_addresses( $text_vcard => $vcard );

        push @{ $self->vcards }, $vcard;
    }
}

sub _copy_simple_nodes {
    my ( $self, $text_vcard, $vcard ) = @_;

    foreach my $node_type ( vCard->_simple_node_types ) {
        next unless $text_vcard->$node_type;
        $vcard->$node_type( $text_vcard->$node_type );
    }
}

sub _copy_phones {
    my ( $self, $text_vcard, $vcard ) = @_;

    my @phones;
    my $nodes = $text_vcard->get('tel') || [];

    foreach my $node (@$nodes) {
        my $phone;
        $phone->{type}      = scalar $node->types;
        $phone->{preferred} = $node->is_pref ? 1 : 0;
        $phone->{number}    = $node->value;
        push @phones, $phone;
    }

    $vcard->phones( \@phones );
}

sub _copy_addresses {
    my ( $self, $text_vcard, $vcard ) = @_;

    my @addresses;
    my $nodes = $text_vcard->get('adr') || [];

    foreach my $node (@$nodes) {
        my $address;
        $address->{type}      = scalar $node->types;
        $address->{preferred} = $node->is_pref ? 1 : 0;
        $address->{po_box}    = $node->po_box || undef;
        $address->{street}    = $node->street || undef;
        $address->{city}      = $node->city || undef;
        $address->{post_code} = $node->post_code || undef;
        $address->{region}    = $node->region || undef;
        $address->{country}   = $node->country || undef;
        $address->{extended}  = $node->extended || undef;
        push @addresses, $address;
    }

    $vcard->addresses( \@addresses );
}

sub _copy_email_addresses {
    my ( $self, $text_vcard, $vcard ) = @_;

    my @email_addresses;
    my $nodes = $text_vcard->get('email') || [];

    foreach my $node (@$nodes) {
        my $email_address;
        $email_address->{type}      = scalar $node->types;
        $email_address->{preferred} = $node->is_pref ? 1 : 0;
        $email_address->{address}   = $node->value;
        push @email_addresses, $email_address;
    }

    $vcard->email_addresses( \@email_addresses );
}

=head2 as_file($filename)

Write all the vCards to $filename.  Files are written as UTF-8 by default.
Returns a L<Path::Class::File> object if successful.  Dies if not successful.

=cut

sub as_file {
    my ( $self, $filename ) = @_;

    my $file = ref $filename eq 'Path::Class::File'    #
        ? $filename
        : file($filename);

    my @iomode = $self->encoding_in eq 'none'          #
        ? ()
        : ( iomode => '<:encoding(' . $self->encoding_out . ')' );

    $file->spew( @iomode, $self->as_string, );

    return $file;
}

=head2 as_string()

Returns all the vCards as a single string.

=cut

sub as_string {
    my ($self) = @_;
    my $string = '';
    $string .= $_->as_string for @{ $self->vcards };
    return $string;
}

=head1 AUTHOR

Eric Johnson (kablamo), github ~!at!~ iijo dot org

=head1 ACKNOWLEDGEMENTS

Thanks to L<Foxtons|http://foxtons.co.uk> for making this module possible by
donating a significant amount of developer time.

=cut

1;
