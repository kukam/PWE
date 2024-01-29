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

function addpercent_progress(dst, percent) {

    if (!dst) {
        return;
    } else if(!dst.attr('id')) {
        return;
    }

    var id = dst.attr('id');

    var waiting = "waiting for response...";

    if ($('html').attr('lang') == 'cs_CZ') {
        waiting = 'čekám na odpověd...';
    }

    if (percent == 100) {
        $("#" + id + "-percent_progress").html(" " + waiting);
    } else {
        $("#" + id + "-percent_progress").html(" (" + percent + "%) ");
    }
}