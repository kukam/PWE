{
    #http: //stackoverflow.com/questions/1766046/postgresql-create-table-if-not-exists
    #EXAMPLES: http: //www.alberton.info/postgresql_meta_info.html#.VEzr8XX5OCg
    # POSTGRES DATA TYPE: http://www.tutorialspoint.com/postgresql/postgresql_data_types.htm
    1 => "
        CREATE TABLE users (
            uid             SERIAL          NOT NULL        PRIMARY KEY,
            fullname        VARCHAR(128)    NOT NULL,
            created         DATE        DEFAULT         NOW()
        )
    ",
    2 => "ALTER TABLE users ALTER COLUMN created TYPE timestamp with time zone;",
    3 => "ALTER TABLE users ADD COLUMN updated timestamp with time zone;",
    4 => "ALTER TABLE users ALTER COLUMN updated SET DEFAULT NOW();",
    5 => "ALTER TABLE users ALTER COLUMN updated SET DEFAULT NULL;",
    6 => "ALTER TABLE users ADD COLUMN email VARCHAR(128);",
    7 => "ALTER TABLE users ALTER COLUMN email DROP NOT NULL;",
    8 => "ALTER TABLE users ALTER COLUMN email SET DEFAULT NULL;",
    9 => "CREATE TABLE dbtable (

    id             	SERIAL          		NOT NULL        PRIMARY KEY,
    name		VARCHAR(128)			NULL,
    sid		VARCHAR(128)			NOT NULL,
    page		VARCHAR(128)			NULL,
    func		VARCHAR(128)			NULL,
    tmpl		VARCHAR(256)			NULL,
    script		VARCHAR(256)			NULL,
    rowcount	INTEGER				NULL            DEFAULT 0,
    endpage		SMALLINT			NULL            DEFAULT 0,

    query		TEXT				NOT NULL,
    conditions	TEXT				NOT NULL,
    ordercolumn	VARCHAR(64)			NULL,
    orderby		VARCHAR(64)			NULL            DEFAULT 'ASC',
    groupby		VARCHAR(128)			NULL,   
    maxrow		INTEGER				NULL            DEFAULT 40,
    gopage		INTEGER				NULL            DEFAULT 1,
    nlimit		SMALLINT			NULL,

        updated         TIMESTAMP WITH TIME ZONE	NULL,
        created         TIMESTAMP WITH TIME ZONE	NOT NULL        DEFAULT NOW()
    );",
    10 => "ALTER TABLE users ADD COLUMN active BOOLEAN DEFAULT FALSE;",
    11 => "ALTER TABLE users DROP COLUMN email;",
    12 => "
    CREATE TABLE session (
        sid             VARCHAR(256)          		NOT NULL    PRIMARY KEY,
        useragent	    VARCHAR(256)          		NOT NULL,
        ipaddres        VARCHAR(128)          		NOT NULL,
        admin		    BOOLEAN 			        NOT NULL	DEFAULT FALSE,
        messenger	    TEXT				        NULL,
        expire		    INT				            NOT NULL,
        updated         TIMESTAMP WITH TIME ZONE	NULL,
        created         TIMESTAMP WITH TIME ZONE	NOT NULL 	DEFAULT NOW()
    );",
    13 => "ALTER TABLE dbtable ADD COLUMN appendurl	VARCHAR(256) NULL;",
    14 => "ALTER TABLE session ADD COLUMN lang VARCHAR(32) DEFAULT 'CZE';",
    15 => "
        ALTER TABLE dbtable ADD COLUMN  dbid VARCHAR(32)  NOT NULL    DEFAULT 'db1';
    ",
};