package Hessian::Translator::V2;

use Moose::Role;
use version; our $VERSION = qv('0.0.1');

use Switch;
use YAML;
use Hessian::Exception;
use Hessian::Translator::Numeric qw/:input_handle/;
use Hessian::Translator::String qw/:input_handle/;
use Hessian::Translator::Date qw/:input_handle/;
use Hessian::Translator::Binary qw/:input_handle/;
use Simple;


sub  read_message_chunk_data { #{{{
    my ($self, $first_bit) = @_;
    my $input_handle = $self->input_handle();
    my $datastructure;
    switch ($first_bit) {
        case /\x48/ {       # TOP with version
            my $hessian_version = $self->read_version();
            $datastructure = { hessian_version => $hessian_version };
        }
#        case /\x43/ {       # Hessian Remote Procedure Call
#             # call will need to be dispatched to object designated in some kind of
#             # service descriptor
#            $datastructure =
#              "Server side remote procedure " . "calls not implemented.";
#        }
        case /\x45/ {    # Envelope
            $datastructure = $self->read_envelope();

        }
        case /\x46/ {    # Fault
            my $result                = $self->deserialize_data();
            my $exception_name        = $result->{code};
            my $exception_description = $result->{message};
            $datastructure =
              $exception_name->new( error => $exception_description );
        }
        case /\x52/ {    # Reply
            my $reply_data = $self->deserialize_data();
            $datastructure = { reply_data => $reply_data };
        }
        else {
            $datastructure =
              $self->deserialize_data( { first_bit => $first_bit } );
        }
    }
    return $datastructure;
} #}}}

sub read_composite_data {    #{{{
    my ( $self, $first_bit ) = @_;
    my $input_handle = $self->input_handle();
    my ( $datastructure, $save_reference );
    switch ($first_bit) {
        case /[\x55\x56\x70-\x77]/ {    # typed lists
            push @{ $self->reference_list() }, [];
            $datastructure  = $self->read_typed_list( $first_bit, );
        }

        case /[\x57\x58\x78-\x7f]/ {    # untyped lists
            push @{ $self->reference_list() }, [];
            $datastructure  = $self->read_untyped_list( $first_bit, );
        }
        case /\x48/ {
            push @{ $self->reference_list() }, {};
            $datastructure  = $self->read_map_handle();
        }
        case /\x4d/ {                   # typed map


            push @{ $self->reference_list() }, {};
            # Get the type for this map. This seems to be more like a
            # perl style object or "blessed hash".

            my $entity_type   = $self->read_hessian_chunk();
            my $map_type = $self->store_fetch_type($entity_type);
            my $map      = $self->read_map_handle();
            $datastructure = bless $map, $map_type;

        }
        case /[\x43\x4f\x60-\x6f]/ {
            $datastructure = $self->read_class_handle( $first_bit, );

        }
    }
#    push @{ $self->reference_list() }, $datastructure
#      if $save_reference;
    return $datastructure;

}    #}}}

sub read_typed_list {    #{{{
    my ( $self, $first_bit ) = @_;
    my $input_handle  = $self->input_handle();
    my $entity_type   = $self->read_hessian_chunk();
    my $type          = $self->store_fetch_type($entity_type);
    my $array_length  = $self->read_list_length($first_bit);
    my $datastructure = $self->reference_list()->[-1];
    my $index         = 0;
  LISTLOOP:
    {
        last LISTLOOP if ( $array_length and ( $index == $array_length ) );
        my $element;
        eval { $element = $self->read_typed_list_element($type); };
        last LISTLOOP
          if $first_bit =~ /\x55/
              && Exception::Class->caught('EndOfInput::X');

        push @{$datastructure}, $element;
        $index++;
        redo LISTLOOP;
    }
    return $datastructure;
}    #}}}

# version 2 specific
sub read_class_handle {    #{{{
    my ( $self, $first_bit ) = @_;
    my $input_handle = $self->input_handle();
    my ( $save_reference, $datastructure );
    switch ($first_bit) {
        case /\x43/ {      # Read class definition
            my $class_type = $self->read_hessian_chunk();
            $class_type =~ s/\./::/g;    # get rid of java stuff
                                         # Get number of fields
            $datastructure = $self->store_class_definition($class_type);
        }
        case /\x4f/ {    # Read hessian data and create instance of class
            $save_reference = 1;
            $datastructure = $self->fetch_class_for_data();
        }
        case /[\x60-\x6f]/ {    # The class definition is in the ref list
            $save_reference = 1;
            my $hex_bit = unpack 'C*', $first_bit;
            my $class_definition_number = $hex_bit - 0x60;
            $datastructure = $self->instantiate_class($class_definition_number);
        }
    }
    push @{ $self->reference_list() }, $datastructure
      if $save_reference;
    return $datastructure;
}    #}}}

# mostly version 2 specific
sub read_map_handle {    #{{{
    my $self         = shift;
    my $input_handle = $self->input_handle();

    # For now only accept integers or strings as keys
    my @key_value_pairs;
  MAPLOOP:
    {
        my $key;
        eval { $key = $self->read_hessian_chunk($input_handle); };
        last MAPLOOP if Exception::Class->caught('EndOfInput::X');
        my $value = $self->read_hessian_chunk($input_handle);
        push @key_value_pairs, $key => $value;
        redo MAPLOOP;
    }

    # should throw an exception if @key_value_pairs has an odd number of
    # elements
    my $hash = {@key_value_pairs};
    my $datastructure = $self->reference_list()->[-1];
    foreach my $key (keys %{$hash}) {
        $datastructure->{$key} = $hash->{$key};
    }
    return $datastructure;

}    #}}}

# version 2 specific
sub read_untyped_list {    #{{{
    my ( $self, $first_bit ) = @_;
    my $input_handle = $self->input_handle();
    my $array_length = $self->read_list_length( $first_bit, );

    my $datastructure = [];
    my $index         = 0;
  LISTLOOP:
    {
        last LISTLOOP if ( $array_length and ( $index == $array_length ) );
        my $element;
        eval { $element = $self->read_hessian_chunk(); };
        last LISTLOOP
          if $first_bit =~ /\x57/
              && Exception::Class->caught('EndOfInput::X');

        push @{$datastructure}, $element;
        $index++;
        redo LISTLOOP;
    }
    return $datastructure;
}    #}}}

sub read_simple_datastructure { #{{{
    my ($self, $first_bit) = @_;
    my $input_handle = $self->input_handle();
    my $element;
    switch ($first_bit) {
        case /\x4e/ {    # 'N' for NULL
            $element = undef;
        }
        case /[\x46\x54]/ {    # 'T'rue or 'F'alse
            $element = read_boolean_handle_chunk($first_bit);
        }
        case /[\x49\x80-\xbf\xc0-\xcf\xd0-\xd7]/ {
            $element = read_integer_handle_chunk( $first_bit, $input_handle );
        }
        case /[\x4c\x59\xd8-\xef\xf0-\xff\x38-\x3f]/ {
            $element = read_long_handle_chunk( $first_bit, $input_handle );
        }
        case /[\x44\x5b-\x5f]/ {
            $element = read_double_handle_chunk( $first_bit, $input_handle );
        }
        case /[\x4a\x4b]/ {
            $element = read_date_handle_chunk( $first_bit, $input_handle );
        }
        case /[\x52\x53\x00-\x1f\x30-\x33]/ {    #   for version 1: \x73
            $element = read_string_handle_chunk( $first_bit, $input_handle );
        }
        case /[\x41\x42\x20-\x2f\x34-\x37\x62]/ {
            $element = read_binary_handle_chunk( $first_bit, $input_handle );
        }
        case /[\x43\x4d\x4f\x48\x55-\x58\x60-\x6f\x70-\x7f]/
        {                                        # recursive datastructure
            $element = $self->read_composite_datastructure( $first_bit, );
        }
        case /\x51/ {
            my $reference_id = $self->read_hessian_chunk();
            $element = $self->reference_list()->[$reference_id];

        }
    }
    binmode( $input_handle, 'bytes' );
    return $element;

} #}}}

"one, but we're not the same";

__END__


=head1 NAME

Hessian::Translator::List - Translate list datastructures to and from hessian.

=head1 VERSION

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 INTERFACE




