package Hessian::Translator::Composite;

#use strict;
#use warnings;

use Moose::Role;
use version; our $VERSION = qv('0.0.1');
#use base 'Hessian::Translator::Message';

with 'Hessian::Translator::Envelope';

requires qw/input_handle/;

#use Perl6::Export::Attrs;
use Switch;
use YAML;
use Hessian::Exception;
use Hessian::Translator::Numeric qw/:input_handle/;
use Hessian::Translator::String qw/:input_handle/;
use Hessian::Translator::Date qw/:input_handle/;
use Hessian::Translator::Binary qw/:input_handle/;

sub read_list {#: Export(:from_hessian) {    #{{{
    my $hessian_list = shift;
    my $array        = [];
    if ( $hessian_list =~ /^  \x57  (.*)  Z/xms ) {
        $array = read_variable_untyped_list($1);
    }

    return $array;
}    #}}}

sub write_list {#: Export(:to_hessian) {    #{{{
    my $list = shift;
}    #}}}

sub read_composite_datastructure {#: Export(:input_handle) {    #{{{
    my ($self, $first_bit) = @_;
    my $input_handle = $self->input_handle();
    my ( $datastructure, $save_reference );
    binmode( $input_handle, 'bytes' );
    switch ($first_bit) {
        case /[\x55\x56\x70-\x77]/ {                          # typed lists
            print "Reading typed list\n";
            $save_reference = 1;
            $datastructure = $self->read_typed_list( $first_bit,);
        }

        case /[\x57\x58\x78-\x7f]/ {                          # untyped lists
            $save_reference = 1;
            $datastructure = $self->read_untyped_list( $first_bit, );
        }
        case /\x48/ {
            $save_reference = 1;
            $datastructure  = $self->read_map_handle();
        }
        case /\x4d/ {                                         # typed map

            $save_reference = 1;

            # Get the type for this map. This seems to be more like a
            # perl style object or "blessed hash".

            # Handle fucked up 't' processing
            my $map;
            if ( $self->is_version_1() ) {
                print "deserializer is version 1\n";

            }
            else {
                my $map_type = $self->read_hessian_chunk();
                if ( $map_type !~ /^\d+$/ ) {
                    push @{ $self->type_list() }, $map_type;
                }
                else {
                    $map_type = $self->type_list()->[$map_type];
                }
                $map = $self->read_map_handle();
                $datastructure = bless $map, $map_type;
            }

        }
        case /[\x43\x4f\x60-\x6f]/ {
            $datastructure = $self->read_class_handle( $first_bit, );

        }
    }
    push @{ $self->reference_list() }, $datastructure
      if $save_reference;
    return $datastructure;

}    #}}}

sub read_version1_map {    #{{{
    my $self = shift;
    my $input_handle = $self->input_handle();
    my $version1_t;
    read $input_handle, $version1_t, 1;
    my ( $type, $first_key_value_pair );
    if ( $version1_t eq 't' ) {
        $type = $self->read_hessian_chunk();
    }
    else {

        # no type, so read the rest of the chunk to get the actual
        # datastructure
        my $key;
        switch ($version1_t) {
            case /[\x49\x80-\xbf\xc0-\xcf\xd0-\xd7]/ {
                $key = read_integer_handle_chunk( $version1_t, $input_handle );
            }
            case /[\x52\x53\x00-\x1f\x30-\x33\x73]/ {
                $key = read_string_handle_chunk( $version1_t, $input_handle );
            }
        }

        # now read the next element out to make sure the remaining has has
        # an even number of elements
        my $value = $self->read_hessian_chunk();
    }

}    #}}}

sub read_typed_list {    #{{{
    my ($self, $first_bit) = @_;
    my $input_handle = $self->input_handle();
    my $type          = $self->read_hessian_chunk();
    print "Type of list is $type\n";
    my $array_length  = $self->read_list_length( $first_bit );
    my $datastructure = [];
    my $index         = 0;
  LISTLOOP:
    {
        last LISTLOOP if ( $array_length and ( $index == $array_length ) );
        my $element;
        eval { $element = $self->read_typed_list_element( $type); };
        last LISTLOOP
          if $first_bit =~ /\x55/
              && Exception::Class->caught('EndOfInput::X');

        push @{$datastructure}, $element;
        $index++;
        redo LISTLOOP;
    }
    return $datastructure;
}    #}}}

sub read_class_handle {    #{{{
    my ($self, $first_bit ) = @_;
    my $input_handle = $self->input_handle();
    my ( $save_reference, $datastructure );
    switch ($first_bit) {
        case /\x43/ {      # Read class definition
            my $class_type = $self->read_hessian_chunk();
            $class_type =~ s/\./::/g;    # get rid of java stuff
                                         # Get number of fields
            my $length;
            read $input_handle, $length, 1;
            my $number_of_fields =
              read_integer_handle_chunk( $length, $input_handle );
            my @field_list;
            foreach my $field_index ( 1 .. $number_of_fields ) {

                # using the wrong function here, but who cares?
                my $field = $self->read_hessian_chunk();
                push @field_list, $field;

            }

            my $class_definition =
              { type => $class_type, fields => \@field_list };
            push @{ $self->class_definitions() }, $class_definition;
            $datastructure = $class_definition;
        }
        case /\x4f/ {    # Read hessian data and create instance of class
            my $length;
            $save_reference = 1;
            read $input_handle, $length, 1;
            my $class_definition_number =
              read_integer_handle_chunk( $length, $input_handle );
            $datastructure =
              $self->instantiate_class($class_definition_number);

        }
        case /[\x60-\x6f]/ {    # The class definition is in the ref list
            $save_reference = 1;
            my $hex_bit = unpack 'C*', $first_bit;
            my $class_definition_number = $hex_bit - 0x60;
            $datastructure =
              $self->instantiate_class($class_definition_number);
        }
    }
    push @{ $self->reference_list() }, $datastructure
      if $save_reference;
    return $datastructure;
}    #}}}

sub read_map_handle {    #{{{
    my $self  = shift;
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
    my $datastructure = {@key_value_pairs};
    return $datastructure;

}    #}}}

sub read_list_length {    #{{{
    my ($self, $first_bit) = @_;
    my $input_handle = $self->input_handle();

    my $array_length;
    if ( $first_bit =~ /[\x56\x58]/ ) {    # read array length
        my $length;
        read $input_handle, $length, 1;
        $array_length = read_integer_handle_chunk( $length, $input_handle );
    }
    elsif ( $first_bit =~ /[\x70-\x77]/ ) {
        my $hex_bit = unpack 'C*', $first_bit;
        $array_length = $hex_bit - 0x70;
    }
    elsif ( $first_bit =~ /[\x78-\x7f]/ ) {
        my $hex_bit = unpack 'C*', $first_bit;
        $array_length = $hex_bit - 0x78;
    }
    return $array_length;
}    #}}}

sub read_untyped_list {    #{{{
    my ($self, $first_bit) = @_;
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

sub read_typed_list_element {    #{{{
    my ($self, $entity_type) = @_;
    my $input_handle = $self->input_handle();
    my ( $type, $element, $first_bit );
#    my $deserializer = __PACKAGE__->get_deserializer();
    binmode( $input_handle, 'bytes' );
    read $input_handle, $first_bit, 1;
    EndOfInput::X->throw( error => 'Reached end of datastructure.' )
      if $first_bit =~ /z/i;
    my $map_type = 'map';

    if ( $entity_type !~ /^\d+$/ ) {
        $type = $entity_type;
        push @{ $self->type_list() }, $type;

    }
    else {
        $type = $self->type_list()->[$entity_type];
    }

    switch ($type) {
        case /boolean/ {
            $element = read_boolean_handle_chunk($first_bit);
        }
        case /int/ {
            $element = read_integer_handle_chunk( $first_bit, $input_handle );
        }
        case /long/ {
            $element = read_long_handle_chunk( $first_bit, $input_handle );
        }
        case /double/ {
            $element = read_double_handle_chunk( $first_bit, $input_handle );
        }
        case /date/ {
            $element = read_date_handle_chunk( $first_bit, $input_handle );
        }
        case /string/ {
            $element = read_string_handle_chunk( $first_bit, $input_handle );
        }
        case /binary/ {
            $element = read_binary_handle_chunk( $first_bit, $input_handle );
        }
        case /list/ {
            $element =
              $self->read_composite_datastructure( $first_bit, );
        }

        #        case /$map_type/ {

        #        }
    }
    return $element;
}    #}}}

sub read_hessian_chunk {#: Export(:deserialize) {    #{{{
    my ( $self, $args ) = @_;
    my $input_handle = $self->input_handle();
    binmode( $input_handle, 'bytes' );
    my ( $first_bit, $element );
    if ( $args->{first_bit}) {
        $first_bit = $args->{first_bit};
    }
    else {
      read $input_handle, $first_bit, 1;    
    }
     
    EndOfInput::X->throw( error => 'Reached end of datastructure.' )
      if $first_bit =~ /z/i;

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
        case /[\x52\x53\x00-\x1f\x30-\x33]/ {#   for version 1: \x73
            $element = read_string_handle_chunk( $first_bit, $input_handle );
        }
        case /[\x41\x42\x20-\x2f\x34-\x37\x62]/ {
            $element = read_binary_handle_chunk( $first_bit, $input_handle );
        }
        case /[\x43\x4d\x4f\x48\x55-\x58\x60-\x6f\x70-\x7f]/
        {    # recursive datastructure
            $element =
              read_composite_datastructure( $first_bit, $input_handle );
        }
        case /\x51/ {
            my $reference_id = $self->read_hessian_chunk();
            $element = $self->reference_list()->[$reference_id];

        }
    }
    binmode( $input_handle, 'bytes' );
    return $element;

}    #}}}

sub read_list_type {    #{{{
    my $self = shift;
    my $input_handle = $self->input_handle();
    my $type_length;
    read $input_handle, $type_length, 1;
    my $type = read_string_handle_chunk( $type_length, $input_handle );
    binmode( $input_handle, 'bytes' );
    return $type;
}    #}}}

sub deserialize_data {    #{{{
    my ( $self, $args ) = @_;

    # Yes, I'm passing the object itself as a parameter so I can add
    # references, class definitions and objects to the different lists as they
    # occur.
    my $result = $self->read_hessian_chunk($args );
    return $result;
}    #}}}

sub instantiate_class {    #{{{
    my ( $self, $index ) = @_;
    my $class_definitions = $self->class_definitions;
    my $class_definition  = $self->class_definitions()->[$index];

    my $class_type = $class_definition->{type};
    my $simple_obj = bless {}, $class_type;
    {

        # This is so we can take advantage of Class::MOP/Moose's meta object
        # capabilities and add arbitrary fields to the new object.
        no strict 'refs';
        push @{ $class_type . '::ISA' }, 'Simple';
    }
    foreach my $field ( @{ $class_definition->{fields} } ) {
        $simple_obj->meta()->add_attribute( $field, is => 'rw' );

        # We're going to assume that fields are submitted in the same order
        # the class fields were defined.  If a field should be empty, then a
        # NULL should be submitted
        my $value = $self->deserialize_data();
        $simple_obj->$field($value);
    }
    return $simple_obj;
}    #}}}

"one, but we're not the same";

__END__


=head1 NAME

Hessian::Translator::List - Translate list datastructures to and from hessian.

=head1 VERSION

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 INTERFACE




