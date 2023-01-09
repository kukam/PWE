{
    1 => "
        CREATE TABLE IF NOT EXISTS `dbtable` (
            id 			INT(8)				UNSIGNED NOT NULL AUTO_INCREMENT,
            name		VARCHAR(128)			NULL            DEFAULT NULL,
            dbid		VARCHAR(32)			NOT NULL        DEFAULT 'db1',
            sid			VARCHAR(128)			NULL            DEFAULT NULL,
            page		VARCHAR(128)			NULL            DEFAULT NULL,
            func		VARCHAR(128)			NULL            DEFAULT NULL,
            tmpl		VARCHAR(255)			NULL            DEFAULT NULL,
            script		VARCHAR(255)			NULL            DEFAULT NULL,
            query		TEXT				NOT NULL,
            conditions		TEXT				NOT NULL,
            ordercolumn		VARCHAR(64)			NULL            DEFAULT NULL,
            orderby		VARCHAR(64)			NULL            DEFAULT 'ASC',
            groupby		VARCHAR(128)			NULL            DEFAULT NULL,   
            maxrow		INTEGER				NULL            DEFAULT 40,
            gopage		INTEGER				NULL            DEFAULT 1,
            rowcount		INTEGER				NULL            DEFAULT 0,
            endpage		SMALLINT			NULL            DEFAULT 0,
            appendurl		VARCHAR(255)			NULL,
            nlimit		SMALLINT			NULL            DEFAULT NULL,
            updated		TIMESTAMP 			NULL            DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
            created		TIMESTAMP			NOT NULL        DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `name`  (`name`),
            KEY `sid`   (`sid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_czech_ci AUTO_INCREMENT=0;
    ",
    2 => "
        CREATE TABLE IF NOT EXISTS `users` (
            uid			INT(8)		UNSIGNED NOT NULL AUTO_INCREMENT,
            fullname		VARCHAR(128)	NOT NULL,
            active		VARCHAR(1)	NOT NULL        DEFAULT 'f',
            updated		TIMESTAMP	NULL            DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
            created		TIMESTAMP	NOT NULL        DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`uid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_czech_ci AUTO_INCREMENT=0;
    ",
    3 => "
        CREATE TABLE IF NOT EXISTS `session` (
            sid		VARCHAR(255)	NOT NULL,
            useragent	VARCHAR(255)	NOT NULL,
            ipaddres	VARCHAR(128)	NOT NULL,
            admin	VARCHAR(1)	NOT NULL     DEFAULT 'f',
            messenger	TEXT		NULL,
            lang	VARCHAR(32) 	NOT NULL     DEFAULT 'CZE',
            expire	INT(12)		NOT NULL,
            updated	TIMESTAMP	NULL         DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
            created	TIMESTAMP	NOT NULL     DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY  (`sid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_czech_ci;",
}