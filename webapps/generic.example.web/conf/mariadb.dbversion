{
    1 => "
        CREATE TABLE `dbtable` (
          `id` int(8) unsigned NOT NULL AUTO_INCREMENT,
          `name` varchar(128) DEFAULT NULL,
          `dbid` varchar(32) NOT NULL DEFAULT 'db1',
          `sid` varchar(128) DEFAULT NULL,
          `page` varchar(128) DEFAULT NULL,
          `func` varchar(128) DEFAULT NULL,
          `tmpl` varchar(255) DEFAULT NULL,
          `script` varchar(255) DEFAULT NULL,
          `query` text NOT NULL,
          `conditions` text NOT NULL,
          `ordercolumn` varchar(64) DEFAULT NULL,
          `orderby` varchar(64) DEFAULT 'ASC',
          `groupby` varchar(128) DEFAULT NULL,
          `maxrow` int(11) DEFAULT 40,
          `gopage` int(11) DEFAULT 1,
          `rowcount` int(11) DEFAULT 0,
          `endpage` smallint(6) DEFAULT 0,
          `appendurl` varchar(255) DEFAULT NULL,
          `nlimit` smallint(6) DEFAULT NULL,
          `updated` timestamp NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
          `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (`id`),
          KEY `name` (`name`),
          KEY `sid` (`sid`)
        ) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_czech_ci;
    ",
    2 => "
        CREATE TABLE `session` (
          `sid` varchar(255) NOT NULL,
          `useragent` varchar(255) NOT NULL,
          `ipaddres` varchar(128) NOT NULL,
          `admin` enum ('t', 'f') NOT NULL DEFAULT 'f',
          `messenger` text DEFAULT NULL,
          `lang` varchar(32) NOT NULL DEFAULT 'CZE',
          `expire` int(12) NOT NULL,
          `updated` timestamp NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
          `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (`sid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_czech_ci;
    ",
    3 => "
        CREATE TABLE `users` (
          `uid` int(8) unsigned NOT NULL AUTO_INCREMENT,
          `fullname` varchar(128) NOT NULL,
          `active` enum ('t', 'f') NOT NULL DEFAULT 'f',
          `updated` timestamp NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
          `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (`uid`)
        ) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_czech_ci;
    "
}