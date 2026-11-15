/* pwe.js - klientska cast AJAX vrstvy enginu PWE
 *
 * Zavislosti (nacitat v tomto poradi, viz Sites/Default/layout_header.html):
 *   jquery.js            (jQuery 4)
 *   bootstrap.bundle.js  (Bootstrap 5.3)
 *   ajaxprogress.js      (addprogress, addpercent_progress - indikace prubehu requestu)
 *
 * Kazdy AJAX request posila parametr ajax_request=1; stranka na serveru podle nej pozna, ze ma
 * odpovedet AJAXem ($WEB->printHttpHeader(type => 'ajax') + $WEB->printAjaxLayout()) misto
 * cele HTML stranky. Odpoved je bud HTML fragment (replaceHTMLSimple), nebo JSON
 * {"REPLACE":[{"ID":"element","HTML":"..."}]} (replaceHTML, AjaxFormAppender), ktery se
 * rozkopiruje do elementu podle ID. Chybove stavy (400/401/404/500) vraci HTML chybove stranky,
 * z ktere se vyjme #messenger-body a zobrazi v #messenger.
 *
 * Odkazy v sablonach generuje templates/href.tmpl:
 *   [% INCLUDE templates/href.tmpl href="$script_name?page=x&func=y" ajaxjson=1 %]   -> replaceHTML(...)
 *   [% INCLUDE templates/href.tmpl href="..." ajaxhtml=1 dst="$('#cil')" %]          -> replaceHTMLSimple(...)
 * Formulare: <script>$(function() { AjaxFormAppender($("#idformulare")); });</script>
 *
 * Namety na rozsireni (globalni udalosti ajaxStart/ajaxStop):
 *   http://stackoverflow.com/questions/8358422/extending-jquerys-ajax-function
 *   http://hayageek.com/examples/jquery/ajax-form-submit/index.php
 */

/*
 * replaceHTMLSimple(url, src, dst)
 *
 * Jednoduchy AJAX s HTML backendem: stahne url (GET, prida ajax_request=1) a vysledne HTML
 * vlozi do elementu dst. Server odpovida fragmentem HTML (napr. $WEB->genTmpl(...)).
 *
 *   url - adresa stranky/akce, napr. "pwe.fcgi?page=ajaxExamples&func=replaceHTMLSimple"
 *   src - jQuery element, na kterem se zobrazi indikator prubehu (typicky $(this) = kliknuty odkaz)
 *   dst - jQuery element, do ktereho se vlozi odpoved
 *
 *   <a href="" onclick="replaceHTMLSimple('pwe.fcgi?page=x&func=y', $(this), $('#replacediv')); return false;">ajax</a>
 *   <div id="replacediv"></div>
 */

function replaceHTMLSimple(url,src,dst) {

    $.ajaxSetup({
        url: url + (url.indexOf('?') != -1 ? "&ajax_request=1" : "?ajax_request=1"),
        global: false,
        type: "GET",
        dataType: "html",
    });

    $.ajax(getAjaxAppender(src,dst));
}

/*
 * replaceHTML(url, src, dst)
 *
 * AJAX s JSON backendem s pevnou strukturou: stahne url (GET, prida ajax_request=1) a ocekava
 * JSON {"REPLACE":[{"ID":"idelementu","HTML":"..."}, ...]} - kazdy prvek nahradi obsah elementu
 * s danym ID. Server ho vytvori pres $WEB->printAjaxLayout(ajax_id => [...], ajax_tmpl => [...]).
 * Polozka s ID "messenger" je flash zprava; pokud v odpovedi chybi, #messenger se vyprazdni.
 *
 *   url - adresa stranky/akce
 *   src - jQuery element s indikatorem prubehu (typicky $(this))
 *   dst - nepouziva se (cile urcuje JSON), ponechano kvuli stejne signature jako replaceHTMLSimple
 *
 *   <a href="" onclick="replaceHTML('pwe.fcgi?page=x&func=y', $(this)); return false;">ajax</a>
 *   <div id="messenger"></div>
 *   <div id="replacediv2"></div>
 */

function replaceHTML(url,src,dst) {

    $.ajaxSetup({
        url: url + (url.indexOf('?') != -1 ? "&ajax_request=1" : "?ajax_request=1"),
        global: false,
        type: "GET",
        dataType: "JSON",
    });

    $.ajax(getAjaxAppender(src,dst));
}

/*
 * getAjaxAppender(src, dst)
 *
 * Vrati objekt nastaveni pro $.ajax() spolecny vsem AJAX volanim enginu (pouzivaji ho
 * replaceHTMLSimple, replaceHTML i AjaxFormAppender; url/type/data se nastavi predem
 * pres $.ajaxSetup). Obsahuje:
 *
 *   beforeSend  - zapne indikator prubehu nad elementem src (addprogress)
 *   statusCode  - pro 0 (spojeni spadlo) a HTTP 400/401/404/413/500 vypne indikator, z HTML
 *                 chybove stranky serveru vyjme #messenger-body, zobrazi ho v #messenger,
 *                 odroluje na nej a do #DATA_DUMPER (DataDump modal ve vyvoji) zapise kod chyby
 *   complete    - pokud server poslal hlavicku AjaxRedirect (printHttpHeader type ajax_redirect),
 *                 presmeruje prohlizec na danou adresu
 *   success     - vypne indikator; odpoved text/html vlozi cela do dst, odpoved JSON
 *                 ("text/xml" hlavicka HttpHeaderAjax.tmpl) projde pole REPLACE a nahradi obsah
 *                 elementu podle ID; bez polozky "messenger" se #messenger vyprazdni, s polozkou
 *                 se na nej odroluje, pokud sablona neobsahuje <span id="disablescrolltomessenger">
 *                 (parametr disable_scrolltomessenger v setMessenger)
 *
 *   src - jQuery element pro indikator prubehu (musi mit atribut id, jinak se indikator nezobrazi)
 *   dst - jQuery element pro HTML odpoved
 */

function getAjaxAppender(src,dst) {

    return {
        statusCode: {
            0: function(response) {
                addprogress(src, 'end');
                scrollToMessenger();
                $('#messenger').html("Broken Pipe error");
                $("#DATA_DUMPER").html("Broken Pipe error");
            },
            400: function(response) {
                addprogress(src, 'end');
                scrollToMessenger();
                h = $.parseHTML(response.responseText);
                $('#messenger').html($(h).find('#messenger-body'));
                $("#DATA_DUMPER").html("Error code: 400");
            },
            401: function(response) {
                addprogress(src, 'end');
                scrollToMessenger();
                h = $.parseHTML(response.responseText);
                $('#messenger').html($(h).find('#messenger-body'));
                $("#DATA_DUMPER").html("Error code: 401");
            },
            404: function(response) {
                addprogress(src, 'end');
                scrollToMessenger();
                h = $.parseHTML(response.responseText);
                $('#messenger').html($(h).find('#messenger-body'));
                $("#DATA_DUMPER").html("Error code: 404");
            },
            413: function(response) {
                addprogress(src, 'end');
                scrollToMessenger();
                h = $.parseHTML(response.responseText);
                $('#messenger').html($(h).find('#messenger-body'));
                $("#DATA_DUMPER").html("Error code: 413");
            },
            500: function(response) {
                addprogress(src, 'end');
                scrollToMessenger();
                h = $.parseHTML(response.responseText);
                $('#messenger').html($(h).find('#messenger-body'));
                $("#DATA_DUMPER").html("Error code: 500");
            }
        },
        error: function(xmlHttp, status, error) {},
        beforeSend: function(xmlHttp, settings) {
            addprogress(src, 'start');
        },
        complete: function(xmlHttp, status) {
            if (xmlHttp.getResponseHeader('AjaxRedirect')) {
                window.location.href = xmlHttp.getResponseHeader('AjaxRedirect');
            }
        },
        success: function(response, status, xmlHttp) {
            addprogress(src, 'end');
            if (xmlHttp.getResponseHeader('Content-Type').match(/text\/html;/)) {
                dst.html(response);
                $("#DATA_DUMPER").html(response);
            } else if (xmlHttp.getResponseHeader('Content-Type').match(/text\/xml;/)) {
                $.each(response, function(key, value) {
                    if (key == "REPLACE") {
                        var removeMessenger = 1;
                        var disable_scrollToMessenger = 0;
                        for (var i in value) {
                            $("#" + value[i].ID).html(value[i].HTML);
                            if (value[i].ID == "messenger") {
                                removeMessenger = 0;
                                // <span id="disablescrolltomessenger"> v messengeru = neodrolovavat (setMessenger(..., disable_scrolltomessenger => 1))
                                if ($($.parseHTML(value[i].HTML)).find('#disablescrolltomessenger').length) {
                                    disable_scrollToMessenger = 1;
                                }
                            }
                        }
                        if (removeMessenger) {
                            $('#messenger').html('');
                        } else if (!disable_scrollToMessenger) {
                            scrollToMessenger();
                        }
                    }
                });
                $("#DATA_DUMPER").html(JSON.stringify(response));
            }
        }
    };
}

/*
 * AjaxFormAppender(form)
 *
 * Prepne formular na odesilani AJAXem: po odeslani (submit) posbira data, prida ajax_request=1
 * a jmeno+hodnotu stisknuteho submit tlacitka, odesle je na action formulare a odpoved zpracuje
 * stejne jako replaceHTML (JSON REPLACE; chyby validace 400 -> messenger). Pri uspechu formular
 * vynuluje; na #messenger odroluje jen success handler z getAjaxAppender, tj. jen kdyz odpoved
 * obsahuje polozku messenger bez #disablescrolltomessenger (setMessenger(..., disable_scrolltomessenger => 1)
 * stranku neodroluje - napr. "pridano do kosiku" u karty dole na strance). Behem uploadu
 * zobrazuje procenta (addpercent_progress).
 *
 * Podle enctype formulare:
 *   multipart/form-data               - FormData (upload souboru), vzdy POST
 *   text/plain                        - serializovana data, hlavicka text/plain
 *   (vychozi) x-www-form-urlencoded   - serializovana data
 *
 * Formular musi mit atribut id (indikator prubehu) a POST formulare musi posilat page a func
 * ve skrytych polich (CGI na POST ignoruje query string). Pouziti:
 *
 *   <form id="mujform" action="pwe.fcgi?page=x&func=form" method="POST">...</form>
 *   <script>$(function() { AjaxFormAppender($("#mujform")); });</script>
 *
 *   form - jQuery objekt formulare
 */

function AjaxFormAppender(form) {

    form.on("submit", function(event) {

        var btn = $(this).find("input[type=submit]:focus");
        var action = $(this).attr("action");
        var method = $(this).attr("method");
        var enctype = $(this).attr("enctype");

        var data = null;
        var processData = true;
        var dataType = "JSON";

        if (enctype === "multipart/form-data") {
            data = new FormData(this);
            data.append("ajax_request", 1);
            method = "POST";
            processData = false;
            enctype = enctype + "; charset=utf-8";
            console.log('form enctype: multipart/form-data');
        } else if (enctype === "text/plain") {
            data = $(this).serialize() + "&ajax_request=1" + "&" + btn.attr("name") + "=" + btn.attr("value");
            enctype = enctype + "; charset=utf-8";
            console.log('form enctype: text/plain');
        } else {
            data = $(this).serialize() + "&ajax_request=1" + "&" + btn.attr("name") + "=" + btn.attr("value");
            enctype = "application/x-www-form-urlencoded; charset=utf-8";
            console.log('form enctype: application/x-www-form-urlencoded');
        }

        $.ajaxSetup({
            url: action,
            global: false,
            type: method,
            data: data,
            dataType: dataType,
            processData: processData,
            contentType: enctype,
            xhr: function() {
                var xhr = new window.XMLHttpRequest();
                //Upload progress
                xhr.upload.addEventListener("progress", function(evt) {
                    if (evt.lengthComputable) {
                        var percentComplete = evt.loaded / evt.total;
                        //Do something with upload progress
                        addpercent_progress(form, (percentComplete * 100).toFixed(0));
                        console.log(percentComplete);
                    }
                }, false);
                //Download progress
                xhr.addEventListener("progress", function(evt) {
                    if (evt.lengthComputable) {
                        var percentComplete = evt.loaded / evt.total;
                        //Do something with download progress
                        addpercent_progress(form, (percentComplete * 100).toFixed(0));
                        console.log(percentComplete);
                    }
                }, false);
                return xhr;
            },
        });

        $.ajax(getAjaxAppender(form,form)).done(function(response, status, xmlHttp) {
            // scroll ridi success handler podle messengeru v odpovedi (disable_scrolltomessenger)
            $(form)[0].reset();
        });

        event.preventDefault();
    });
}

/*
 * scrollToMessenger()
 *
 * Plynule odroluje stranku na element #messenger (flash zprava), aby uzivatel videl vysledek
 * AJAX akce. Pokud #messenger na strance neni, nic nedela.
 */

function scrollToMessenger() {
    var messenger = $("#messenger");
    if (!messenger.length) {
        return;
    }
    $('html,body').animate({
        scrollTop: (messenger.offset().top - 10)
    }, 'slow');
}
