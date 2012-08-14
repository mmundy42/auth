package Bio::KBase::AuthToken;

use strict;
use warnings;
use JSON;
use Bio::KBase::Auth;
use LWP::UserAgent;
use Digest::SHA1 qw(sha1_base64);
use Crypt::OpenSSL::RSA;
use Crypt::OpenSSL::X509;
use MIME::Base64;
use URI;
use URI::QueryParam;
use POSIX;

# We use Object::Tiny::RW to generate getters/setters for the attributes
# and save ourselves some tedium
use Object::Tiny::RW qw {
    error_message
    user_id
    password
    client_secret
};

our @trust_token_signers = ( 'https://graph.api.go.sandbox.globuscs.info/goauth/keys/da0a4e96-e22a-11e1-9b09-1231381bc4c2');
# Set a token lifetime of 12 hours
our $token_lifetime = 12 * 60 * 60;

sub new() {
    my $class = shift;

    # Don't bother with calling the Object::Tiny::RW constructor,
    # since it doesn't do anything except return a blessed empty hash
    my $self = $class->SUPER::new(
        'token' => undef,
        'error_message' => undef,
        @_
    );

    eval {
	# If we were given a token, try set that using the formal setter
	# elsif we have appropriate login credentials, try to get a
	# token
	if ($self->{'token'}) {
	    $self->token( $self->{'token'});
	} elsif ($self->{'user_id'} &&
		 ($self->{'password'} || $self->{'client_secret'})) {
	    $self->get();
	}
    };
    if ($@) {
	$self->error_message("Failed to acquire token: $@");
    }
    return($self);
}

# getter/setter for token, if we are given a token, parse it out
# and set the appropriate attributes 
sub token {
    my $self = shift @_;
    my $token = shift;

    unless( $token) {
	return( $self->{'token'});
    }

    # parse out token and set user_id
    eval {
	$self->{'token'} = $token;
	($self->{'user_id'}) = $token =~ /un=(\w+)/;
	unless ($self->{'user_id'}) {
	    die "Cannot parse user_id from token - illegal token";
	}
    };
    if ($@) {
	$self->error_message("Invalid token: $@");
	return( undef);
    } else {
	$self->{'error_message'} = undef;
	return( $token);
    }
}

# Get a nexus token, using either user_id, password or user_id, rsakey.
# Parameters looked for within $self:
# body => body of the http message, if any, can be undefined
# user_id => user name recognized on globus online for login
# client_id => user name recognized on globus online for login
# client_secret => the RSA private key used for signing
# password => Globus online password
# Throws an exception if either invalid set of creds or failed login

sub get {
    my $self = shift @_;
    my %p = @_;
    my $path = $Bio::KBase::Auth::AuthorizePath;
    my $url = $Bio::KBase::Auth::AuthSvcHost;
    my $method = "GET";
    my %headers;
    my $res;

    eval {
	if ($p{'user_id'}) {
	    $self->user_id($p{'user_id'});
	}
	if ($p{'client_secret'}) {
	    $self->client_secret($p{'client_secret'});
	}
	if ($p{'password'}) {
	    $self->password($p{'password'});
	}

	# Make sure we have the right combo of creds
	if ($self->{'user_id'} && ($self->{'client_secret'} || $self->{'password'})) {
	    # no op
	} else {
	    die("Need either (user_id, client_secret || password) or (client_id, client_secret) to be defined.");
	}
	
	my $u = URI->new($url);
	my %qparams = ("response_type" => "code",
		       "client_id" => $self->{'client_id'} ? $self->{'client_id'} : $self->{'user_id'});
	$u->query_form( %qparams );
	my $query=$u->query();
	
	# Okay, if we have user_id/password, create a basic auth header and extract it
	# otherwise create a set of RSA signature headers using
	# user_id and client_secret
	my $headers;
	if ( $self->{'user_id'} && $self->{'password'}) {
	    $headers = HTTP::Headers->new;
	    $headers->authorization_basic( $self->{'user_id'}, $self->{'password'});
	    $headers{'Authorization'} = $headers->header('Authorization');
	} else {
	    my %p2 = ( rsakey => $self->{'client_secret'},
		       path => $path,
		       method => $method,
		       user_id => $self->{'user_id'},
		       query => $query,
		       body => $self->{'body'} );
	    
	    %headers = sign_with_rsa( %p2);
	}
	my $path2 = sprintf('%s?%s',$path,$query);
	$res = $self->go_request( "path" => $path2, 'headers' => \%headers);
	unless ($res->{'code'}) {
	    die "No token returned by Globus Online";
	}
    };
    if ($@) {
	$self->{'token'} = undef;
	$self->{'user_id'} = undef;
	die "Failed to get auth token: $@";
    } else {
	return($self->token( $res->{'code'}));
    }
}

# The basic sha1_base64 does not properly pad the encoded text
# so we have this little wrapper to tack on extra '='.
sub sha1_base64_padded {
    my $in = shift;
    my @pad = ('','===','==','=');

    my $out = sha1_base64( $in);
    return ($out.$pad[length($out) % 4]);
}

# Return a hash of HTTP headers used by Globus Nexus to authenticate
# a token request.
sub sign_with_rsa {
    my %p = @_;
    my %headers;

    eval {
	# The sha1_base64 functions choke on an undefs, so
	# set body to an empty string if it is undef
	unless (defined($p{'body'})) {
	    $p{'body'} = "";
	}
	my $timestamp = canonical_time(time());
	%headers = ( 'X-Globus-UserId' => $p{user_id},
			'X-Globus-Sign'   => 'version=1.0',
			'X-Globus-Timestamp' => $timestamp,
	    );
	
	my $to_sign = join("\n",
			   "Method:%s",
			   "Hashed Path:%s",
			   "X-Globus-Content-Hash:%s",
			   "X-Globus-Query-Hash:%s",
			   "X-Globus-Timestamp:%s",
			   "X-Globus-UserId:%s");
	$to_sign = sprintf( $to_sign,
			    $p{method},
			    sha1_base64_padded($p{path}),
			    sha1_base64_padded($p{body}),
			    sha1_base64_padded($p{query}),
			    $timestamp,
			    $headers{'X-Globus-UserId'});
	my $pkey = Crypt::OpenSSL::RSA->new_private_key($p{rsakey});
	$pkey->use_sha1_hash();
	my $sig = $pkey->sign($to_sign);
	my $sig_base64 = encode_base64( $sig);
	my @sig_base64 = split( '\n', $sig_base64);
	foreach my $x (0..$#sig_base64) {
	    $headers{ sprintf( 'X-Globus-Authorization-%s', $x)} = $sig_base64[$x];
	}
    };
    if ($@) {
	die "Could not sign headers: $@";
    } else {
	return(%headers);
    }
}

# Formats a time string in the format desired by Globus Online
# It is somewhat bogus, because they are claiming that it is
# UTC, when in fact its the localtime.           
sub canonical_time {
    my $time = shift;
    return( strftime("%Y-%m-%dT%H:%M:%S", localtime($time)) . 'Z');

}

# Function that returns if the token is valid or not
sub validate {
    my $self = shift;
    my $verify;

    eval {
	unless ($self->{'token'}) {
	    die "No token.";
	}
	my ($sig_data) = $self->{'token'} =~ /^(.*)\|sig=/;
	unless ($sig_data) {
	    die "Token lacks signature fields";
	}
	my %vars = map { split /=/ } split /\|/, $self->{'token'};
	unless (($vars{'expiry'} + $token_lifetime) >= time) {
	    die "Token expired at: ".scalar( localtime($vars{'expiry'} + $token_lifetime)) ;
	}
	my $binary_sig = pack('H*',$vars{'sig'});

	my $client = LWP::UserAgent->new();
	$client->ssl_opts(verify_hostname => 0);
	$client->timeout(5);
	my $response = $client->get( $vars{'SigningSubject'});

	my $data = from_json( $response->content());
	$data = $self->_SquashJSONBool( $data);
	unless ($data->{'valid'}) {
	    die "Signing key is not valid:".$response->content();
	}

	my $rsa = Crypt::OpenSSL::RSA->new_public_key( $data->{'pubkey'});
	$rsa->use_sha1_hash();

	$verify = $rsa->verify($sig_data,$binary_sig);
    };
    if ($@) {
	$self->error_message("Failed to verify token: $@");
	return( undef);
    } else {
	$self->{'error_message'} = undef;
	return( $verify);
    }
}

# function that handles Globus Online requests
# takes the following params in hash
# path => path/query part of the URL, doesn't include protocol/host
# method => (GET|PUT|POST|DELETE) defaults to GET
# body => string for http content
#         Content-Type will be set to application/json
#         automatically
# headers => hashref for any additional headers to be put into
#         the request. X-GLOBUS-GOAUTHTOKEN automatically set
#         by token param
#
# Returns a hashref to the json data that was returned
# throw an exception if there is an error, make sure you
# trap this with an eval{}!

sub go_request {
    my $self = shift @_;
    my %p = @_;

    my $json;
    eval {
	my $baseurl = $Bio::KBase::Auth::AuthSvcHost;
	my %headers;
	unless ($p{'path'}) {
	    die "No path specified";
	}
	$headers{'Content-Type'} = 'application/json';
	if (defined($p{'headers'})) {
	    %headers = (%headers, %{$p{'headers'}});
	}
	my $headers = HTTP::Headers->new( %headers);
    
	my $client = LWP::UserAgent->new(default_headers => $headers);
	$client->timeout(5);
	$client->ssl_opts(verify_hostname => 0);
	my $method = $p{'method'} ? $p{'method'} : "GET";
	my $url = sprintf('%s%s', $baseurl,$p{'path'});
	my $req = HTTP::Request->new($method, $url);
	if ($p{'body'}) {
	    $req->content( $p{'body'});
	}
	my $response = $client->request( $req);
	unless ($response->is_success) {
	    die $response->status_line;
	}
	$json = decode_json( $response->content());
	$json = $self->_SquashJSONBool( $json);
    };
    if ($@) {
	die "Failed to query Globus Online: $@";
    } else {
	return( $json);
    }

}

sub _SquashJSONBool {
    # Walk an object ref returned by from_json() and squash references
    # to JSON::XS::Boolean into a simple 0 or 1
    my $self = shift;
    my $json_ref = shift;
    my $type;

    foreach (keys %$json_ref) {
	$type = ref $json_ref->{$_};
	next unless ($type);
	if ( 'HASH' eq $type) {
	    _SquashJSONBool( $self, $json_ref->{$_});
	} elsif ( 'JSON::XS::Boolean' eq $type) {
	    $json_ref->{$_} = ( $json_ref->{$_} ? 1 : 0 );
	}
    }
    return $json_ref;
}


1;

__END__

=pod

=head1 Bio::KBase::AuthToken

Token object for Globus Online/Globus Nexus tokens. For general information about Globus Nexus service see:
http://globusonline.github.com/nexus-docs/api.html


=head2 Examples

   # Acquiring a new token when you have username/password credentials
   my $token = Bio::KBase::AuthToken->new( 'user_id' => 'mrbig', 'password' => 'bigP@SSword');

   # or if you have an SSH private key for RSA authentication

   my $token2 = Bio::KBase::AuthToken->new( 'user_id' => 'mrbig', 'client_secret' => $rsakey);


   # If you have a token in $tok, and wish to check if it is valid
   my $token3 = Bio::KBase::AuthToken->new( 'token' => $tok);
   if ($token3->validate()) {
       # token is legit
       my $user_id = $token3->user_id();

       # acquiring a full user profile once you have a token
       my $profile = new Bio::KBase::AuthUser->new;
       $profile->get( $token3->token());

   } else {
       die "Begone, evildoer!\n";
   }

=head2 Instance Variables

=over

=item B<user_id> (string)

REQUIRED Userid of the associated with the token

=item B<token> (string)

A string containing a signed assertion from the Globus Nexus service. Here is an example:

un=sychan|clientid=sychan|expiry=1376425658|SigningSubject=https://graph.api.go.sandbox.globuscs.info/goauth/keys/da0a4e96-e22a-11e1-9b09-1231381bc4c2|sig=88cb32eae2782452817f106a2ce8cf9215f3356ce123d43395a5c99c5ec4184eaf5d70111124a06cf9267e5340f1d06b9258cf2e70e8000000000000000000000000000000583c68755de5453b4b019ebf3d7d4547778ef7d6322f2ba8f42d370bbce4b693ef7a9b3c7be3c6970132e72c654e3274afab9ea39ba9724383f1594

   It is a series of name value pairs:
   un = username
   clientid = Globus Nexus client id
   expiry = time when the token was issued
   SigningSubject = url to the public key used to verify the signature
   sig = RSA sha1 signature hash

=item B<password> (string)

The password used to acquire token (if provided). Note that it is not possible to pull down the password from the authentication service.

=item B<client_secret> (string)

An openssh formatted RSA private key string used for authentication

=item B<error_message> (string)

contains error messages, if any, from most recent method call.

=back

=head2 Methods

=over

=item B<new>()

returns a Bio::KBase::AuthToken reference. Optionally pass in hash params to initialize attributes. If we have enough attributes to perform a login either a token, or (user_id,password) or (user_id,client_secret) then the library will try to acquire a new token from Globus Nexus.

   Examples:

   # Acquiring a new token when you have username/password credentials
   my $token = Bio::KBase::AuthToken->new( 'user_id' => 'mrbig', 'password' => 'bigP@SSword');

   # or if you have an SSH private key for RSA authentication

   $rsakey = `cat ~/.id_rsa`;
   my $token2 = Bio::KBase::AuthToken->new( 'user_id' => 'mrbig', 'client_secret' => $rsakey);

   # we have a token string in $tok, and want to verify it
   my $token3 = 
   

=item B<user_id>()

returns the user_id associated with the token, if any. If a single string value is passed in, it will be used to set the value of the user_id

=item B<validate>()

attempts to verify the signature on the token, and returns a boolean value signifying whether the token is legit

=back

=cut