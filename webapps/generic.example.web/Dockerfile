FROM kukam/pwe-base:latest

ADD examples/generic_web/entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /PWE/webapps

ADD Entities Entities
ADD Pages Pages
ADD Services Services
ADD Sites Sites
ADD assets assets
ADD conf conf

# ENTITY
# DBTable Entity.pm Session

# PAGES
# lrwxrwxrwx   1 kukam  staff   28 14 zář  2021 ajaxExamples -> ../../../Pages/ajaxExamples/
# lrwxrwxrwx   1 kukam  staff   19 14 zář  2021 css -> ../../../Pages/css/
# lrwxrwxrwx   1 kukam  staff   25 14 zář  2021 errorPage -> ../../../Pages/errorPage/
# lrwxrwxrwx   1 kukam  staff   28 14 zář  2021 formExamples -> ../../../Pages/formExamples/
# lrwxrwxrwx   1 kukam  staff   26 14 zář  2021 pweCreator -> ../../../Pages/pweCreator/
# lrwxrwxrwx   1 kukam  staff   25 14 zář  2021 showIcons -> ../../../Pages/showIcons/
# lrwxrwxrwx   1 kukam  staff   26 14 zář  2021 systemPage -> ../../../Pages/systemPage/

# Services
# lrwxrwxrwx   1 kukam  staff   26 14 zář  2021 DBTable -> ../../../Services/DBTable/
# lrwxrwxrwx   1 kukam  staff   26 14 zář  2021 Session -> ../../../Services/Session/
# lrwxrwxrwx   1 kukam  staff   30 14 zář  2021 UserAccount -> ../../../Services/UserAccount/

# rm templates pwe.fcgi favicon.ico devel.cgi Libs



        # assets/css/bootstrap-5.2.3
        # assets/javascript/bootstrap-5.2.3
        # assets/javascript/jquery-3.7.1
        # assets/scss/
# awesome_674_20150914 bootstrap-3.2.0      bootstrap-3.3.1
ajax-loader.gif
# ajaxprogress.js bootstrap-3.2.0 bootstrap-3.3.1 bootstrap-5.2.3 jquery-1.11.1   jquery-2.1.1    jquery-3.7.1    pwe.js

ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]

CMD ["perl", "pwe.fcgi"]
