package Hessian::Translator::Envelope;

use Moose::Role;

use Switch;
use YAML;
use Contextual::Return;
use List::MoreUtils qw/any/;

use Hessian::Exception;

sub read_message_chunk {    #{{{
    my $self = shift;
    my ($first_bit);
    $first_bit = $self->read_from_inputhandle(1);
    EndOfInput->throw( error => "Encountered end of datastructure." )
      if $first_bit =~ /z/i;
    my $datastructure = $self->read_message_chunk_data($first_bit);
    return $datastructure;
}    #}}}

sub read_version {    #{{{
    my $self = shift;
    my $version;
    $version = $self->read_from_inputhandle(2);
    my @values = unpack 'C*', $version;
    my $hessian_version = join "." => @values;
    return $hessian_version;

}    #}}}

sub read_envelope {    #{{{
    my $self = shift;
    my ( $first_bit, $packet_body, @chunks );
    $first_bit = $self->read_from_inputhandle(1);
    EndOfInput::X->throw( error => 'End of datastructure.' )
      if $first_bit =~ /z/i;

    # Just the word "Header" as far as I understand
    my $header_string = $self->read_string_handle_chunk($first_bit);
  ENVELOPECHUNKS: {
        my ( $header_count, $footer_count, $packet_size );
        my ( @headers,      @footers,      @packets );
        $first_bit = $self->read_from_inputhandle(1);
        last ENVELOPECHUNKS if $first_bit =~ /z/i;
        $header_count = $self->read_integer_handle_chunk( $first_bit, );
        foreach ( 1 .. $header_count ) {
            push @headers, $self->read_header_or_footer();
        }

      PACKETCHUNKS: {
            $first_bit = $self->read_from_inputhandle(1);
            my $length = unpack "C*", $first_bit;
            $packet_size =
                $first_bit =~ /[\x70-\x7f]/
              ? $length - 0x70
              : $length - 0x80;
            my $packet_string;
            $packet_string = $self->read_from_inputhandle($packet_size);
            $packet_body .= $packet_string;
            last PACKETCHUNKS if $first_bit =~ /[\x80-\x8f]/;
            redo PACKETCHUNKS;
        }

        $first_bit    = $self->read_from_inputhandle(1);
        $footer_count = $self->read_integer_handle_chunk( $first_bit, );
        foreach ( 1 .. $footer_count ) {
            push @footers, $self->read_header_or_footer();
        }
        push @chunks,
          {
            headers => \@headers,
            footers => \@footers
          };
        redo ENVELOPECHUNKS;
    }
    my $packet = $self->read_packet($packet_body);
    return { envelope => { packet => $packet, meta => \@chunks } };
}    #}}}

sub read_header_or_footer {    #{{{
    my $self = shift;

    my $first_bit;
    $first_bit = $self->read_from_inputhandle(1);
    my $header = $self->read_string_handle_chunk($first_bit);
    return $header;
}    #}}}

sub read_packet {    #{{{
    my ( $self, $packet_string ) = @_;
    return FIXED NONVOID {
        $self->deserialize_message( { input_string => $packet_string } );
    };
}    #}}}

sub write_hessian_packet {    #{{{
    my ( $self, $packets ) = @_;
}    #}}}

sub write_hessian_message {    #{{{
    my ( $self, $hessian_data ) = @_;

    my $hessian_message;
    if ( ( ref $hessian_data ) eq 'HASH'
        and any { exists $hessian_data->{$_} } qw/call envelope packet/ )
    {
        my @keys          = keys %{$hessian_data};
        my $datastructure = $hessian_data->{ $keys[0] };
        switch ( $keys[0] ) {
            case /call/ {
                $hessian_message = $self->write_hessian_call($datastructure);
            }
            case /envelope/ {
                $hessian_message =
                  $self->write_hessian_envelope($datastructure);
            }
            case /packet/ {
                $hessian_message = $self->write_hessian_packet($datastructure);
            }
        }
    }
    else {
        $hessian_message = $self->write_hessian_chunk($hessian_data);
    }
    return $hessian_message;
}    #}}}

"one, but we're not the same";

__END__


=head1 NAME

Hessian::Translator::Envelope - Translate envelope level Hessian syntax


=head1 SYNOPSIS

These methods are meant for internal use only.

=head1 DESCRIPTION

This module implements methods necessary for processing the packaging of
Hessian messages. This includes components of Hessian messages like envelopes
and packets (mainly relevant for Hessian 2.0) as well as I<call> and
I<reply> elements.


=head1 INTERFACE

=head2    next_token


=head2    process_message


=head2    read_envelope


=head2    read_envelope_chunk


=head2    read_header_or_footer


=head2    read_message_chunk


=head2    read_packet

=head2 read_version

Reads the version of the message.

=head2 write_hessian_message

Writes a datastructure as a hessian message.

=head2 write_hessian_packet

Write a subset of hessian data out as a packet.


