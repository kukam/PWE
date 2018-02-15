{
    pwe => {
        home              => "/PWE/examples/static_web/",
        upload_dir        => "ramdisk/upload/",
        opts_dir          => "ramdisk/",
        expire_opts_time  => 48,                                                 # hour
        default_tmpl      => "templates/",
        pages_dir         => "Pages/",
        sites_dir         => "Sites/",
        services_dir      => "Services/",
        entities_dir      => "Entities/",
        smtp_servers      => [],
        enable_opt        => 1,
        save_opt_to       => "file",                                             # db / file
        cgi_disableupload => 0,
        cgi_maxfilesize   => (100 * 1048576),                                    # 100MB
        cgi_maxopentries  => 1000,
        cgi_tmpdirectory  => "ramdisk/",
        default_page      => "default",
        default_func      => "default",
        development       => 1,
    },
    
    smtp_primary => {
        host 	    => "localhost",
        port        => 25,
        timeout	    => 5,
        debug 	    => 0,
    },

    css => {
        src_css    => "static",                                                    # less,static
        less_src   => "/assets/less/main/main.less",
        less_out   => "/assets/css/pwe.css",
        less_bin   => "/usr/bin/lessc -x",
        static_css => "/assets/css/pwe.css",
    },

    http => {
        http_host_path      => "/",                                              # path se pouziva pro cookie path
        layout_error_header => "templates/LayoutErrorHeader.html",
        layout_error_body   => "templates/LayoutErrorBody.html",
        languages           => ["CZE", "EN"],
        name                => '*** DEVEL *** PWE EXAMPLE STATIC PAGE',
        title               => '*** DEVEL *** PWE EXAMPLE STATIC PAGE',
        keywords            => 'PWE EXAMPLE STATIC PAGE',
        description         => 'PWE EXAMPLE STATIC PAGE',
        cookie_name         => 'PWE-EXAMPLE-STATIC-PAGE',
        base_url            => 'static.freebox.cz',                              # toto url se pouziva hlavne tam kde kod je spousten z prikazove radky (cron) a kde jsou generovany obsahy z odkazem na dany web
        cookie_expire_guest => 3,
        cookie_expire_user  => 30,
    },

    web => {
        # NASTAVENI CHOVANI WEBU
        email_admin    => 'admin@freebox.cz',
        email_subtitle => '*** DEVEL *** PWE EXAMPLE STATIC PAGE',
    },

    tmpl => {
        croot => "ramdisk/templates/",
        cache => 1,
    },

    log => {
        loglevel           => 4,              # 0=DISABLE, 1=ERROR, 2=INFO, 3=DEBUG, 4=PRINT_OUTPUT
        filter_list        => [],
        error_filter_list  => [],
        info_filter_list   => [],
        debug_filter_list  => [],
        print_filter_list  => [],
        delay_filter_list  => [],
        exclude_list       => [],
        error_exclude_list => [],
        info_exclude_list  => [],
        debug_exclude_list => [],
        print_exclude_list => [],
        delay_exclude_list => [],
        logdir             => "log/",
        log_delay          => 0,                # 1/0 enable/disable
        log_delay_minimum  => "0.001",          # 0.001 = 1ms
    },
};
