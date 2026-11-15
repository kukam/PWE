/* ajaxprogress.js - indikator prubehu AJAX requestu (pouziva pwe.js)
 *
 * Pres element, ze ktereho request vzesel (odkaz, formular), se polozi poloprusvitna vrstva
 * s animaci assets/images/ajax-loader.gif a volitelne s procenty prenosu. Vrstva se identifikuje
 * podle id elementu (<id>-progress), element proto musi mit atribut id.
 */

/*
 * addprogress(dst, process_status)
 *
 * Zapne nebo vypne indikator prubehu nad elementem dst.
 *
 *   dst            - jQuery element (musi mit id; bez nej se nic nestane)
 *   process_status - 'start' = polozit pres element vrstvu <id>-progress s ajax-loaderem
 *                    (stejna pozice a rozmery jako element), cokoliv jineho = vrstvu odstranit
 *
 * Vola getAjaxAppender v pwe.js: beforeSend -> 'start', success/chyba -> 'end'.
 */

function addprogress(dst, process_status) {

    if (!dst) {
        return;
    } else if(!dst.attr('id')) {
        return;
    }

    var id = dst.attr('id');
    var div = "<div id=\"" + id + "-progress\"><center><img src=\"assets/images/ajax-loader.gif\"/> <span id=\"" + id + "-percent_progress\"></span></center></div>";

    if (process_status == 'start') {
        $("body").last().after(div);
        var position = dst.offset();
        $("#" + id + "-progress").offset({
            top: (position.top - 2),
            left: (position.left - 2)
        });
        $("#" + id + "-progress").width(dst.width() + 4);
        $("#" + id + "-progress").height(dst.height() + 4);
        $("#" + id + "-progress").css("background-color", "white");
        $("#" + id + "-progress").css("opacity", "0.85");
        $("#" + id + "-progress").css("padding-top", (dst.height() / 2) + "px");
        $("#" + id + "-percent_progress").css("color", "black");
    } else {
        $("#" + id + "-progress").remove();
    }
}

/*
 * addpercent_progress(dst, percent)
 *
 * Do bezici vrstvy indikatoru (<id>-percent_progress) zapise procenta prenosu; pri 100 %
 * zobrazi text "cekam na odpoved..." (podle lang atributu <html>: cs = cesky, jinak anglicky).
 * Vola AjaxFormAppender z udalosti progress XMLHttpRequestu (upload i download).
 *
 *   dst     - jQuery element s id (formular)
 *   percent - cele cislo 0-100
 */

function addpercent_progress(dst, percent) {

    if (!dst) {
        return;
    } else if(!dst.attr('id')) {
        return;
    }

    var id = dst.attr('id');

    var waiting = "waiting for response...";

    if (($('html').attr('lang') || '').match(/^cs/)) {
        waiting = 'čekám na odpověd...';
    }

    if (percent == 100) {
        $("#" + id + "-percent_progress").html(" " + waiting);
    } else {
        $("#" + id + "-percent_progress").html(" (" + percent + "%) ");
    }
}
