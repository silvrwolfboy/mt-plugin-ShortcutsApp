package MT::Plugin::ShortcutsApp;

use strict;
use warnings;
use utf8;

use File::Spec;
use MT::Util qw(epoch2ts);
use MT::Util::YAML;

sub plugin {
    MT->component( __PACKAGE__ =~ m/::([^:]+)\z/ );
}

sub shortcuts {
    my $top_dir = File::Spec->catdir( plugin()->{full_path}, 'shortcuts' );
    opendir( my $dh, $top_dir )
        or return [];
    my @dirs = grep { $_ !~ m/\A[\.\~]/ } readdir($dh);
    closedir $dh;

    my $lang = MT->instance->current_language;
    ( my $lang_short = $lang ) =~ s/[_-].*//;

    my @shortcuts;
    for my $d (@dirs) {
        my %s         = ( full_path => File::Spec->catdir( $top_dir, $d ), );
        my $yaml_file = File::Spec->catfile( $s{full_path}, 'shortcut.yaml' );
        my $data      = eval { MT::Util::YAML::LoadFile($yaml_file) }
            or next;

        my $lex = $data->{l10n_lexicon}{$lang}
            || $data->{l10n_lexicon}{$lang_short};

        for my $k (qw(name label description)) {
            my $trans = $lex->{ $data->{$k} }
                or next;
            $data->{$k} = $trans;
        }

        $s{data} = $data;
        push @shortcuts, \%s;
    }

    [ sort { $a->{data}{id} cmp $b->{data}{id} } @shortcuts ];
}

sub list_shortcuts {
    my $app = shift;

    my $tmpl = plugin()->load_tmpl('list_shortcuts.tmpl');

    my $blog = $app->blog;
    my $view
        = !$blog            ? 'system'
        : !$blog->parent_id ? 'website'
        :                     'blog';

    my $shortcuts = [
        grep {
            my $s = $_;
            grep { $_ eq $view } @{ $s->{data}{view} };
        } @{ shortcuts() }
    ];

    $tmpl->param(
        {   current_user_id => $app->user->id,
            shortcuts       => $shortcuts,
        }
    );

    $tmpl;
}

sub install_shortcut {
    my $app = shift;
    my $id  = $app->param('id');

    my $user_id = $app->param('user_id');
    if ( !$user_id || !$app->user->is_superuser ) {
        $user_id = $app->user->id;
    }

    my ($shortcut) = grep { $_->{data}{id} eq $id } @{ shortcuts() };
    return unless $shortcut;

    my $sess = MT->model('session')->new;
    $sess->id( $app->make_magic_token() );
    $sess->kind('SA');    #SA == ShortcutsApp
    $sess->start(time);
    $sess->duration(
        time + ( int( $shortcut->{data}{expires_in} ) || 3600 ) );
    $sess->set( 'user_id', $user_id );
    $sess->set( 'id',      $id );
    if ( my $blog = $app->blog ) {
        $sess->set( 'blog_id', $blog->id );
    }
    $sess->save
        or $app->error( $sess->errstr ), return;

    my $tmpl = plugin()->load_tmpl('install_shortcut.tmpl');
    $tmpl->param(
        {   shortcut      => $shortcut,
            shortcut_data => $shortcut->{data},
            token         => $sess->id,
            expires_at    => epoch2ts( $app->blog, $sess->duration ),
        }
    );

    $tmpl;
}

sub _get_shortcut {
    my $app   = shift;
    my $token = scalar $app->param('token');

    my $sess = MT->model('session')->load($token);
    return unless $sess && $sess->kind('SA') && $sess->duration > time();

    my $id = $sess->get('id');

    my ($shortcut) = grep { $_->{data}{id} eq $id } @{ shortcuts() };
    return unless $shortcut;

    my $user_id = $sess->get('user_id');
    my $user    = MT->model('author')->load($user_id);
    return unless $user;

    ( $sess, $shortcut, $user );
}

sub get_shortcut {
    my $app = shift;

    my ( $sess, $shortcut, $user ) = _get_shortcut($app);

    return plugin()->load_tmpl('get_shortcut_expired.tmpl') unless $sess;

    my $tmpl = plugin()->load_tmpl('get_shortcut.tmpl');
    $tmpl->param(
        {   shortcut      => $shortcut,
            shortcut_data => $shortcut->{data},
            token         => $sess->id,
        }
    );

    $tmpl;
}

sub get_shortcut_data {
    my $app = shift;

    my ( $sess, $shortcut, $user ) = _get_shortcut($app);

    return unless $sess;

    my $tmpl = plugin()->load_tmpl(
        File::Spec->catfile(
            $shortcut->{full_path},
            $shortcut->{data}{template}
        )
    );

    return unless $tmpl;

    my $blog;

    $tmpl->context->stash( author => $user );
    if ( my $blog_id = $sess->get('blog_id') ) {
        $blog = MT->model('blog')->load($blog_id);
        $tmpl->context->stash( blog => $blog );
    }

    my $cgi_path
        = $app->config->ShortcutsAppDataAPICGIPath
        || $app->config->CGIPath
        || $app->config->AdminCGIPath;
    if ( $cgi_path =~ m!^/! ) {
        my $b = $blog || MT->model('blog')->load;

        # relative path, prepend blog domain
        my ($blog_domain) = $b->archive_url =~ m|(.+://[^/]+)|;
        if ($blog_domain) {
            $cgi_path = $blog_domain . $cgi_path;
        }
    }
    $cgi_path .= '/' unless $cgi_path =~ m{/$};
    $tmpl->param(
        {   user_api_password => $user->api_password,
            cgi_path          => $cgi_path,
        }
    );

    $tmpl;
}

1;
