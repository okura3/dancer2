package Dancer::Core::Request;
use Moo;

use Carp;
use Encode;
use HTTP::Body;
use URI;
use URI::Escape;
use Dancer::Core::Request::Upload;

with 'Dancer::Core::Role::Headers';

# add an attribute for each HTTP_* variables
my @http_env_keys = (
    'user_agent',      'accept_language', 'accept_charset',
    'accept_encoding', 'keep_alive',      'connection',
    'accept',          'accept_type',     'referer',
    # 'host' is managed manually
);

has $_ => (
      is  => 'rw',
      isa => sub { Dancer::Moo::Types::Str(@_) }
  ) for @http_env_keys;

# then all the native attributes
has env => (
    is => 'ro',
    isa => sub { Dancer::Moo::Types::HashRef(@_) },
    default => sub { {} },
);

has path => (
    is => 'rw',
    isa => sub { Dancer::Moo::Types::Str(@_) },
);

has path_info => (
    is => 'rw',
    isa => sub { Dancer::Moo::Types::Str(@_) },
);

has method => (
    is => 'rw',
    isa => sub { Dancer::Moo::Types::DancerHTTPMethod(@_) },
);

has content_type => (
    is => 'rw',
    isa => sub { Dancer::Moo::Types::Str(@_) },
);

has content_length => (
    is => 'rw',
    isa => sub { Dancer::Moo::Types::Num(@_) },
);

has body => (
    is => 'rw',
    isa => sub { Dancer::Moo::Types::Str(@_) },
    default => '',
);

has id => (
    is => 'rw',
    isa => sub { Dancer::Moo::Types::Num(@_) },
);

has uploads => (
    is => 'rw',
    isa => sub { Dancer::Moo::Types::HashRef(@_) },
);

# Really needed? as we have is_ajax() ...
has ajax => (
    is => 'rw',
    isa => sub { Dancer::Moo::Types::Bool(@_) },
);

has body_is_parsed => (
    is => 'rw',
    isa => sub { Dancer::Moo::Types::Bool(@_) },
    default => 0,
);

has is_behind_proxy => (
    is => 'ro',
    isa => sub { Dancer::Moo::Types::Bool(@_) },
    default => 0,
);

has host => (
    is => 'rw',
    isa => sub { Dancer::Moo::Types::Str( @_ ) },
);

# Some Moo-gic to make host() depend on the flag "is_behind_proxy"
around host => sub {
    my $orig = shift;
    my ($self, @args) = @_;

    # wanted a setter, don't touch anything
    return $self->$orig(@args) if @args == 1;

    # alter the reader
    my $host;
    $host = $self->env->{X_FORWARDED_HOST} 
        if $self->is_behind_proxy;
    return $host || $self->{host} || $self->env->{HTTP_HOST};
};

# aliases, kept for backward compat
sub agent                 { $_[0]->user_agent }
sub remote_address        { $_[0]->address }
sub forwarded_for_address { $_[0]->env->{'X_FORWARDED_FOR'} }
sub address               { $_[0]->env->{REMOTE_ADDR} }
sub remote_host           { $_[0]->env->{REMOTE_HOST} }
sub protocol              { $_[0]->env->{SERVER_PROTOCOL} }
sub port                  { $_[0]->env->{SERVER_PORT} }
sub request_uri           { $_[0]->env->{REQUEST_URI} }
sub user                  { $_[0]->env->{REMOTE_USER} }
sub script_name           { $_[0]->env->{SCRIPT_NAME} }

sub scheme                {
    my ($self) = @_;
    my $scheme;
    if ($self->is_behind_proxy) {
        $scheme = $self->env->{'X_FORWARDED_PROTOCOL'}
               || $self->env->{'HTTP_X_FORWARDED_PROTOCOL'}
               || $self->env->{'HTTP_FORWARDED_PROTO'}
               || "";
    }
    return $scheme
        || $self->env->{'psgi.url_scheme'}
        || $self->env->{'PSGI.URL_SCHEME'}
        || "";
}

sub secure                { $_[0]->scheme eq 'https' }
sub uri                   { $_[0]->request_uri }

sub is_head               { $_[0]->{method} eq 'HEAD' }
sub is_post               { $_[0]->{method} eq 'POST' }
sub is_get                { $_[0]->{method} eq 'GET' }
sub is_put                { $_[0]->{method} eq 'PUT' }
sub is_delete             { $_[0]->{method} eq 'DELETE' }

# public interface compat with CGI.pm objects
sub request_method { method(@_) }
sub input_handle   { $_[0]->env->{'psgi.input'} || $_[0]->env->{'PSGI.INPUT'} }

my $_count = 0;

sub BUILD {
    my ($self) = @_;

    $self->{content_length} = $self->env->{CONTENT_LENGTH} || 0;
    $self->{content_type}   = $self->env->{CONTENT_TYPE} || '';
    $self->{id}             = ++$_count;

    $self->{_chunk_size}    = 4096;
    $self->{_read_position} = 0;
    $self->{_body_params}   = undef;
    $self->{_query_params}  = undef;
    $self->{_route_params}  = {};

    $self->_init_request_headers();
    $self->_build_request_env();
    $self->_build_path();      
    $self->_build_path_info() ;
    $self->_build_method();    

    $self->{_http_body} =
      HTTP::Body->new($self->content_type, $self->content_length);
    $self->{_http_body}->cleanup(1);
    
    $self->_build_params();
    $self->_build_uploads();
    
    $self->{ajax} = $self->is_ajax;
}

sub to_string {
    my ($self) = @_;
    return "[#" . $self->id . "] " . $self->method . " " . $self->path;
}

# Create a new request which is a clone of the current one, apart
# from the path location, which points instead to the new location
# TODO this could be written in a more clean manner with a clone mechanism
sub make_forward_to {
    my ($self, $url, $params, $options) = @_;

    my $env = $self->env;
    $env->{PATH_INFO} = $url;

    my $new_request = (ref $self)->new(env => $env, body_is_parsed => 1);
    my $new_params  = _merge_params(scalar($self->params),
                                    $params || {});

    if (exists($options->{method})) {
        $new_request->method(uc $options->{method});
    }

    $new_request->{params}  = $new_params;
    $new_request->_set_body_params($self->{_body_params});
    $new_request->_set_query_params($self->{_query_params});
    $new_request->_set_route_params($self->{_route_params});
    $new_request->{_params_are_decoded} = 1;
    $new_request->{body}    = $self->body;
    $new_request->{headers} = $self->headers;

    return $new_request;
}

sub forward {
    my $new_request = shift->make_forward_to(@_);
    return Dancer->runner->server->dispatcher->dispatch(
               $new_request->env, $new_request
           )->content;
}

sub _merge_params {
    my ($params, $to_add) = @_;

    for my $key (keys %$to_add) {
        $params->{$key} = $to_add->{$key};
    }
    return $params;
}

sub base {
    my $self = shift;
    my $uri  = $self->_common_uri;

    return $uri->canonical;
}

sub _common_uri {
    my $self = shift;

    my $path   = $self->env->{SCRIPT_NAME};
    my $port   = $self->env->{SERVER_PORT};
    my $server = $self->env->{SERVER_NAME};
    my $host   = $self->host;
    my $scheme = $self->scheme;

    my $uri = URI->new;
    $uri->scheme($scheme);
    $uri->authority($host || "$server:$port");
    $uri->path($path      || '/');

    return $uri;
}

sub uri_base {
    my $self  = shift;
    my $uri   = $self->_common_uri;
    my $canon = $uri->canonical;

    if ( $uri->path eq '/' ) {
        $canon =~ s{/$}{};
    }

    return $canon;
}

sub uri_for {
    my ($self, $part, $params, $dont_escape) = @_;
    my $uri = $self->base;

    # Make sure there's exactly one slash between the base and the new part
    my $base = $uri->path;
    $base =~ s|/$||;
    $part =~ s|^/||;
    $uri->path("$base/$part");

    $uri->query_form($params) if $params;

    return $dont_escape ? uri_unescape($uri->canonical) : $uri->canonical;
}

sub params {
    my ($self, $source) = @_;
    my @caller = caller;

    if (not $self->{_params_are_decoded}) {
        $self->{params}        = _decode($self->{params});
        $self->{_body_params}  = _decode($self->{_body_params});
        $self->{_query_params} = _decode($self->{_query_params});
        $self->{_route_params} = _decode($self->{_route_params});
        $self->{_params_are_decoded} = 1;
    }

    return %{$self->{params}} if wantarray && @_ == 1;
    return $self->{params} if @_ == 1;

    if ($source eq 'query') {
        return %{$self->{_query_params}} if wantarray;
        return $self->{_query_params};
    }
    elsif ($source eq 'body') {
        return %{$self->{_body_params}} if wantarray;
        return $self->{_body_params};
    }
    if ($source eq 'route') {
        return %{$self->{_route_params}} if wantarray;
        return $self->{_route_params};
    }
    else {
        croak "Unknown source params \"$source\".";
    }
}

sub captures { shift->params->{captures} }

sub splat { @{shift->params->{splat}||[]} }

sub param { shift->params->{$_[0]} }

sub _decode {
    my ($h) = @_;
    return if not defined $h;

    if (!ref($h) && !utf8::is_utf8($h)) {
        return decode('UTF-8', $h);
    }

    if (ref($h) eq 'HASH') {
        while (my ($k, $v) = each(%$h)) {
            $h->{$k} = _decode($v);
        }
        return $h;
    }

    if (ref($h) eq 'ARRAY') {
        return [ map { _decode($_) } @$h ];
    }

    return $h;
}

sub is_ajax {
    my $self = shift;

    return 0 unless defined $self->headers;
    return 0 unless defined $self->header('X-Requested-With');
    return 0 if $self->header('X-Requested-With') ne 'XMLHttpRequest';
    return 1;
}

# context-aware accessor for uploads
sub upload {
    my ($self, $name) = @_;
    my $res = $self->{uploads}{$name};

    return $res unless wantarray;
    return ()   unless defined $res;
    return (ref($res) eq 'ARRAY') ? @$res : $res;
}

# TODO : move these into attributes
sub _set_route_params {
    my ($self, $params) = @_;
    $self->{_route_params} = $params;
    $self->_build_params();
}

sub _set_body_params {
    my ($self, $params) = @_;
    $self->{_body_params} = $params;
    $self->_build_params();
}

sub _set_query_params {
    my ($self, $params) = @_;
    $self->{_query_params} = $params;
    $self->_build_params();
}

sub _build_request_env {
    my ($self) = @_;

   # Don't refactor that, it's called whenever a request object is needed, that
   # means at least once per request. If refactored in a loop, this will cost 4
   # times more than the following static map.
    $self->{user_agent}       = $self->env->{HTTP_USER_AGENT};
    $self->{host}             = $self->env->{HTTP_HOST};
    $self->{accept_language}  = $self->env->{HTTP_ACCEPT_LANGUAGE};
    $self->{accept_charset}   = $self->env->{HTTP_ACCEPT_CHARSET};
    $self->{accept_encoding}  = $self->env->{HTTP_ACCEPT_ENCODING};
    $self->{keep_alive}       = $self->env->{HTTP_KEEP_ALIVE};
    $self->{connection}       = $self->env->{HTTP_CONNECTION};
    $self->{accept}           = $self->env->{HTTP_ACCEPT};
    $self->{accept_type}      = $self->env->{HTTP_ACCEPT_TYPE};
    $self->{referer}          = $self->env->{HTTP_REFERER};
    $self->{x_requested_with} = $self->env->{HTTP_X_REQUESTED_WITH};
}

sub _build_params {
    my ($self) = @_;

    # params may have been populated by before filters
    # _before_ we get there, so we have to save it first
    my $previous = $self->{params} || {};

    # now parse environement params...
    $self->_parse_get_params();
    if ($self->{body_is_parsed}) {
        $self->{_body_params} ||= {};
    } else {
        $self->_parse_post_params();
    }

    # and merge everything
    $self->{params} = {
        %$previous,                %{$self->{_query_params}},
        %{$self->{_route_params}}, %{$self->{_body_params}},
    };

}

# Written from PSGI specs:
# http://search.cpan.org/dist/PSGI/PSGI.pod
sub _build_path {
    my ($self) = @_;
    my $path = "";

    $path .= $self->script_name if defined $self->script_name;
    $path .= $self->env->{PATH_INFO} if defined $self->env->{PATH_INFO};

    # fallback to REQUEST_URI if nothing found
    # we have to decode it, according to PSGI specs.
    if (defined $self->request_uri) {
        $path ||= $self->_url_decode($self->request_uri);
    }

    croak "Cannot resolve path" if not $path;
    $self->{path} = $path;
}

sub _build_path_info {
    my ($self) = @_;
    my $info = $self->env->{PATH_INFO};
    if (defined $info) {

        # Empty path info will be interpreted as "root".
        $info ||= '/';
    }
    else {
        $info = $self->path;
    }
    $self->{path_info} = $info;
}

sub _build_method {
    my ($self) = @_;
    $self->{method} = $self->env->{REQUEST_METHOD};
}

sub _url_decode {
    my ($self, $encoded) = @_;
    my $clean = $encoded;
    $clean =~ tr/\+/ /;
    $clean =~ s/%([a-fA-F0-9]{2})/pack "H2", $1/eg;
    return $clean;
}

sub _parse_post_params {
    my ($self) = @_;
    return $self->{_body_params} if defined $self->{_body_params};

    my $body = $self->_read_to_end();
    $self->{_body_params} = $self->{_http_body}->param;
}

sub _parse_get_params {
    my ($self) = @_;
    return $self->{_query_params} if defined $self->{_query_params};
    $self->{_query_params} = {};

    my $source = $self->env->{QUERY_STRING} || '';
    foreach my $token (split /[&;]/, $source) {
        my ($key, $val) = split(/=/, $token);
        next unless defined $key;
        $val = (defined $val) ? $val : '';
        $key = $self->_url_decode($key);
        $val = $self->_url_decode($val);

        # looking for multi-value params
        if (exists $self->{_query_params}{$key}) {
            my $prev_val = $self->{_query_params}{$key};
            if (ref($prev_val) && ref($prev_val) eq 'ARRAY') {
                push @{$self->{_query_params}{$key}}, $val;
            }
            else {
                $self->{_query_params}{$key} = [$prev_val, $val];
            }
        }

        # simple value param (first time we see it)
        else {
            $self->{_query_params}{$key} = $val;
        }
    }
    return $self->{_query_params};
}

sub _read_to_end {
    my ($self) = @_;

    my $content_length = $self->content_length;
    return unless $self->_has_something_to_read();

    if ($content_length > 0) {
        while (my $buffer = $self->_read()) {
            $self->{body} .= $buffer;
            $self->{_http_body}->add($buffer);
        }
    }

    return $self->{body};
}

sub _has_something_to_read {
    my ($self) = @_;
    return 0 unless defined $self->input_handle;
}

# taken from Miyagawa's Plack::Request::BodyParser
sub _read {
    my ($self,)   = @_;
    my $remaining = $self->content_length - $self->{_read_position};
    my $maxlength = $self->{_chunk_size};

    return if ($remaining <= 0);

    my $readlen = ($remaining > $maxlength) ? $maxlength : $remaining;
    my $buffer;
    my $rc;

    $rc = $self->input_handle->read($buffer, $readlen);

    if (defined $rc) {
        $self->{_read_position} += $rc;
        return $buffer;
    }
    else {
        croak "Unknown error reading input: $!";
    }
}

sub _init_request_headers {
    my ($self) = @_;
    my $env = $self->env;

    $self->headers(
        HTTP::Headers->new(
            map {
                (my $field = $_) =~ s/^HTTPS?_//;
                ($field => $env->{$_});
              }
              grep {/^(?:HTTP|CONTENT|COOKIE)/i} keys %$env
        )
    );
}

# Taken gently from Plack::Request, thanks to Plack authors.
sub _build_uploads {
    my ($self) = @_;

    my $uploads = _decode($self->{_http_body}->upload);
    my %uploads;

    for my $name (keys %{$uploads}) {
        my $files = $uploads->{$name};
        $files = ref $files eq 'ARRAY' ? $files : [$files];

        my @uploads;
        for my $upload (@{$files}) {
            push(
                @uploads,
                Dancer::Core::Request::Upload->new(
                    headers  => $upload->{headers},
                    tempname => $upload->{tempname},
                    size     => $upload->{size},
                    filename => $upload->{filename},
                )
            );
        }
        $uploads{$name} = @uploads > 1 ? \@uploads : $uploads[0];

        # support access to the filename as a normal param
        my @filenames = map { $_->{filename} } @uploads;
        $self->{_body_params}{$name} =
          @filenames > 1 ? \@filenames : $filenames[0];
    }

    $self->{uploads} = \%uploads;
    $self->_build_params();
}

has cookies => (
    is => 'rw',
    isa => sub { HashRef(@_) },
    lazy => 1,
    builder => '_build_cookies',
);

sub _build_cookies {
    my ($self) = @_;

    my $env_str = $self->env->{COOKIE} || $self->env->{HTTP_COOKIE};
    return {} unless defined $env_str;

    my $cookies = {};
    foreach my $cookie ( split( /[,;]\s/, $env_str ) ) {
        # here, we don't want more than the 2 first elements
        # a cookie string can contains something like:
        # cookie_name="foo=bar"
        # we want `cookie_name' as the value and `foo=bar' as the value
        my( $name,$value ) = split(/\s*=\s*/, $cookie, 2);
        my @values;
        if ( $value ne '' ) {
            @values = map { uri_unescape($_) } split( /[&;]/, $value );
        }
        $cookies->{$name} =
          Dancer::Core::Cookie->new( name => $name, value => \@values );
    }
    return $cookies;
}


1;

__END__

=pod

=head1 NAME

Dancer::Request - interface for accessing incoming requests

=head1 DESCRIPTION

This class implements a common interface for accessing incoming requests in
a Dancer application.

In a route handler, the current request object can be accessed by the C<request>
method, like in the following example:

    get '/foo' => sub {
        request->params; # request, params parsed as a hash ref
        request->body; # returns the request body, unparsed
        request->path; # the path requested by the client
        # ...
    };

A route handler should not read the environment by itself, but should instead
use the current request object.

=head1 PUBLIC INTERFACE

=head2 new()

The constructor of the class, used internally by Dancer's core to create request
objects.

It uses the environment hash table given to build the request object:

    Dancer::Request->new(env => \%ENV);

It also accepts the C<body_is_parsed> boolean flag, if the new request object should
not parse request body.

=head2 init()

Used internally to define some default values and parse parameters.

=head2 new_for_request($method, $path, $params, $body, $headers)

An alternate constructor convienient for test scripts which creates a request
object with the arguments given.

=head2 forward($request, $new_location)

Create a new request which is a clone of the current one, apart
from the path location, which points instead to the new location.
This is used internally to chain requests using the forward keyword.

Note that the new location should be a hash reference. Only one key is
required, the C<to_url>, that should point to the URL that forward
will use. Optional values are the key C<params> to a hash of
parameters to be added to the current request parameters, and the key
C<options> that points to a hash of options about the redirect (for
instance, C<method> pointing to a new request method).

=head2 to_string()

Return a string representing the request object (eg: C<"GET /some/path">)

=head2 method()

Return the HTTP method used by the client to access the application.

While this method returns the method string as provided by the environment, it's
better to use one of the following boolean accessors if you want to inspect the
requested method.

=head2 address()

Return the IP address of the client.

=head2 remote_host()

Return the remote host of the client. This only works with web servers configured
to do a reverse DNS lookup on the client's IP address.

=head2 protocol()

Return the protocol (HTTP/1.0 or HTTP/1.1) used for the request.

=head2 port()

Return the port of the server.

=head2 uri()

An alias to request_uri()

=head2 request_uri()

Return the raw, undecoded request URI path.

=head2 user()

Return remote user if defined.

=head2 script_name()

Return script_name from the environment.

=head2 scheme()

Return the scheme of the request

=head2 secure()

Return true of false, indicating whether the connection is secure

=head2 is_get()

Return true if the method requested by the client is 'GET'

=head2 is_head()

Return true if the method requested by the client is 'HEAD'

=head2 is_post()

Return true if the method requested by the client is 'POST'

=head2 is_put()

Return true if the method requested by the client is 'PUT'

=head2 is_delete()

Return true if the method requested by the client is 'DELETE'

=head2 path()

Return the path requested by the client.

=head2 base()

Returns an absolute URI for the base of the application.  Returns a L<URI>
object (which stringifies to the URL, as you'd expect).

=head2 uri_base()

Same thing as C<base> above, except it removes the last trailing slash in the
path if it is the only path.

This means that if your base is I<http://myserver/>, C<uri_base> will return
I<http://myserver> (notice no trailing slash). This is considered very useful
when using templates to do the following thing:

    <link rel="stylesheet" href="<% request.uri_base %>/css/style.css" />

=head2 uri_for(path, params)

Constructs a URI from the base and the passed path.  If params (hashref) is
supplied, these are added to the query string of the uri.  If the base is
C<http://localhost:5000/foo>, C<< request->uri_for('/bar', { baz => 'baz' }) >>
would return C<http://localhost:5000/foo/bar?baz=baz>.  Returns a L<URI> object
(which stringifies to the URL, as you'd expect).

=head2 params($source)

Called in scalar context, returns a hashref of params, either from the specified
source (see below for more info on that) or merging all sources.

So, you can use, for instance:

    my $foo = params->{foo}

If called in list context, returns a list of key => value pairs, so you could use:

    my %allparams = params;


=head3 Fetching only params from a given source

If a required source isn't specified, a mixed hashref (or list of key value
pairs, in list context) will be returned; this will contain params from all
sources (route, query, body).

In practical terms, this means that if the param C<foo> is passed both on the
querystring and in a POST body, you can only access one of them.

If you want to see only params from a given source, you can say so by passing
the C<$source> param to C<params()>:

    my %querystring_params = params('query');
    my %route_params       = params('route');
    my %post_params        = params('body');

If source equals C<route>, then only params parsed from the route pattern
are returned.

If source equals C<query>, then only params parsed from the query string are
returned.

If source equals C<body>, then only params sent in the request body will be
returned.

If another value is given for C<$source>, then an exception is triggered.

=head2 Vars

Alias to the C<params> accessor, for backward-compatibility with C<CGI> interface.

=head2 request_method

Alias to the C<method> accessor, for backward-compatibility with C<CGI> interface.

=head2 input_handle

Alias to the PSGI input handle (C<< <request->env->{psgi.input}> >>)

=head2 content_type()

Return the content type of the request.

=head2 content_length()

Return the content length of the request.

=head2 header($name)

Return the value of the given header, if present. If the header has multiple
values, returns an the list of values if called in list context, the first one
in scalar.

=head2 body()

Return the raw body of the request, unparsed.

If you need to access the body of the request, you have to use this accessor and
should not try to read C<psgi.input> by hand. C<Dancer::Request> already did it for you
and kept the raw body untouched in there.

=head2 is_ajax()

Return true if the value of the header C<X-Requested-With> is XMLHttpRequest.

=head2 env()

Return the current environment (C<%ENV>), as a hashref.

=head2 uploads()

Returns a reference to a hash containing uploads. Values can be either a
L<Dancer::Request::Upload> object, or an arrayref of L<Dancer::Request::Upload>
objects.

You should probably use the C<upload($name)> accessor instead of manually accessing the
C<uploads> hash table.

=head2 upload($name)

Context-aware accessor for uploads. It's a wrapper around an access to the hash
table provided by C<uploads()>. It looks at the calling context and returns a
corresponding value.

If you have many file uploads under the same name, and call C<upload('name')> in
an array context, the accesor will unroll the ARRAY ref for you:

    my @uploads = request->upload('many_uploads'); # OK

Whereas with a manual access to the hash table, you'll end up with one element
in @uploads, being the ARRAY ref:

    my @uploads = request->uploads->{'many_uploads'}; # $uploads[0]: ARRAY(0xXXXXX)

That is why this accessor should be used instead of a manual access to
C<uploads>.

=head1 HTTP environment variables

All HTTP environment variables that are in %ENV will be provided in the
Dancer::Request object through specific accessors, here are those supported:

=over 4

=item C<accept>

=item C<accept_charset>

=item C<accept_encoding>

=item C<accept_language>

=item C<accept_type>

=item C<agent> (alias for C<user_agent>)

=item C<connection>

=item C<forwarded_for_address>

=item C<forwarded_protocol>

=item C<forwarded_host>

=item C<host>

=item C<keep_alive>

=item C<path_info>

=item C<referer>

=item C<remote_address>

=item C<user_agent>

=back


=head1 AUTHORS

This module has been written by Alexis Sukrieh and was mostly
inspired by L<Plack::Request>, written by Tatsuiko Miyagawa.

Tatsuiko Miyagawa also gave a hand for the PSGI interface.

=head1 LICENCE

This module is released under the same terms as Perl itself.

=head1 SEE ALSO

L<Dancer>

=cut
