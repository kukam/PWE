/* Base javascript */

/* Dependency :
 * ajaxprogress.js
 * bootstrap.js
 * jquery.js
 */


/* TODO :
 * (AJAX-START,AJAX-STOP) : http://stackoverflow.com/questions/8358422/extending-jquerys-ajax-function
 * http://hayageek.com/examples/jquery/ajax-form-submit/index.php
 */

/*
 * Jednoducha AJAX fuknce s HTML backendem
 * 
 * <a href="javascript:replaceHTMLSimple("/ajax-backend.html",$(#replacediv));">ajax</a>
 * <div id="replacediv"></div>
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
 * Rozsirujici funkce pro AJAX s JSON backendem s definovanou strukturou.
 *
 * <a href="javascript:replaceHTML("/ajax-backend.json");">ajax</a>
 * <div id="messanger"></div>
 * <div id="replacediv2"></div>
 * <div id="replacediv3"></div>
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
 * getAjaxAppender
 *
 * TODO : Dopsat popis
 * 
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
                                if($($.parseHTML(value[i].HTML)).find('#disablescrolltomessenger')) {
                                    disable_scrollToMessenger = 0;
                                }
                            }
                        }
                        if (removeMessenger) {
                            $('#messenger').html('');
                        } else if (disable_scrollToMessenger) {
                            scrollToMessenger();
                        }
                    }
                });
                $("#DATA_DUMPER").html(JSON.stringify(response));
            }
        }
    };
}

function AjaxFormAppender(form) {

    form.submit(function(event) {

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
            scrollToMessenger();
            $(form)[0].reset();
        });

        event.preventDefault();
    });
}

function scrollToMessenger() {
    $('html,body').animate({
        scrollTop: ($("#messenger").offset().top - 10)
    }, 'slow');
}