set plugin_name "DPx_Screen_Saver"

namespace eval ::plugins::${plugin_name} {
    # These are shown in the plugin selection page
    variable author "Damian"
    variable contact "via Diaspora"
    variable version 1.5
    variable description "A plugin that allows users to select an alternate screen saver directory, for skins that don't already do so. Pick any folder of .jpg images on your device. ** Use .jpg images only! **"

    # folder browser state
    variable browse_dir ""
    variable browse_entries {}
    variable browse_display {}

    proc size_dir {} { return "${::screen_size_width}x${::screen_size_height}" }

    # Hand-made folder: desktop users drop .jpg files straight in here.
    proc mysaver_root {} { return "[data_directory]/MySaver" }

    # Plugin-owned folder: images copied in from a folder picked on the device.
    # Kept separate from MySaver so re-importing never deletes the user's own files.
    proc imported_root {} { return "[data_directory]/MySaver_imported" }

    proc jpgs_in {dir} {
        return [glob -nocomplain -types f -directory $dir {*.[Jj][Pp][Gg]} {*.[Jj][Pp][Ee][Gg]}]
    }

    # The saver root to use: an imported set wins over the hand-made MySaver folder.
    proc active_root {} {
        foreach root [list [imported_root] [mysaver_root]] {
            # 2560x1600 counts too: the core saver resizes those to this screen on first use
            if {[llength [jpgs_in $root/[size_dir]]] || [llength [jpgs_in $root/2560x1600]]} { return $root }
        }
        return ""
    }

    proc build_ui {} {
        variable browse_dir
        set page_name "DPx_SS_options"

        # Background image and "Done" button
        add_de1_page "$page_name" "settings_message.png" "default"
        add_de1_text $page_name 1280 1310 -text [translate "Done"] -font Helv_10_bold -fill "#fAfBff" -anchor "center"
        add_de1_button $page_name {say [translate {Done}] $::settings(sound_button_in); page_to_show_when_off extensions; }  980 1210 1580 1410 ""

        # Headline
        add_de1_text $page_name 1280 130 -text [translate "DPx Screen Saver"] -font Helv_20_bold -width 1200 -fill "#444444" -anchor "center" -justify "center"

        # Current status
        add_de1_variable $page_name 1280 210 -justify center -anchor "n" -font Helv_8 -fill "#444444" -width 2200 -textvariable {[::plugins::DPx_Screen_Saver::message]}

        # Folder browser: tap a folder to open it, then "Use this folder"
        add_de1_variable $page_name 200 400 -anchor "nw" -font Helv_8_bold -fill "#4e85f4" -width 2100 -textvariable {[::plugins::DPx_Screen_Saver::browse_label]}
        dui add listbox $page_name 200 460 -tags dpx_ss_folders -canvas_width 2100 -canvas_height 560 -yscrollbar 1 \
            -listvariable ::plugins::DPx_Screen_Saver::browse_display \
            -select_cmd {::plugins::DPx_Screen_Saver::browse_select %W}

        dui add dbutton $page_name 200 1060 700 1170 -label [translate "Up"] -label_font Helv_9 -label_fill "#000000" \
            -shape rect -fill "#e6ecfb" -outline "#4e85f4" -width 2 -radius 20 \
            -command {::plugins::DPx_Screen_Saver::browse_to [file dirname $::plugins::DPx_Screen_Saver::browse_dir]}
        dui add dbutton $page_name 1500 1060 2300 1170 -label [translate "Use this folder"] -label_font Helv_9 -label_fill "#000000" \
            -shape rect -fill "#e6ecfb" -outline "#4e85f4" -width 2 -radius 20 \
            -command ::plugins::DPx_Screen_Saver::use_browse_dir

        request_read_permission
        browse_to [start_dir]
        return $page_name
    }

    # Android 13+ replaced READ_EXTERNAL_STORAGE with READ_MEDIA_IMAGES; older
    # versions already get READ_EXTERNAL_STORAGE at app startup.
    proc request_read_permission {} {
        if {$::android != 1 || [ifexists ::android_sdk 0] < 33} { return }
        catch {
            if {[borg checkpermission android.permission.READ_MEDIA_IMAGES] != 1} {
                borg checkpermission android.permission.READ_MEDIA_IMAGES 1
            }
        }
    }

    proc start_dir {} {
        foreach d [list /sdcard/Pictures /sdcard /storage/emulated/0 $::env(HOME)] {
            if {[file isdirectory $d] && [file readable $d]} { return $d }
        }
        return /
    }

    proc browse_label {args} {
        variable browse_dir
        return "$browse_dir   ([llength [jpgs_in $browse_dir]] .jpg)"
    }

    proc browse_to {dir} {
        variable browse_dir
        variable browse_entries
        variable browse_display
        set dirs {}
        catch { set dirs [lsort -dictionary [glob -nocomplain -types d -directory $dir *]] }
        set browse_dir $dir
        set browse_entries $dirs
        set browse_display {}
        foreach d $dirs { lappend browse_display "[file tail $d]/" }
    }

    proc browse_select {widget args} {
        variable browse_entries
        set i [lindex [$widget curselection] 0]
        if {$i eq ""} { return }
        $widget selection clear 0 end
        browse_to [lindex $browse_entries $i]
    }

    # Copy the folder's .jpg files into the plugin-owned saver folder. Copying (not
    # pointing at the folder) is deliberate: the core saver needs a <root>/<WxH>/
    # layout, and an outside folder may be read-only or later lose its permission.
    # ponytail: no resize; images are shown as-is, so they should match the screen size.
    proc use_browse_dir {} {
        variable browse_dir
        set files [jpgs_in $browse_dir]
        if {[llength $files] == 0} {
            popup [translate "No .jpg images in this folder"]
            return
        }
        set dest "[imported_root]/[size_dir]"
        borg spinner on
        set err [catch {
            file delete -force [imported_root]
            file mkdir $dest
            foreach f $files {
                file copy -force $f "$dest/[file rootname [file tail $f]].jpg"
            }
        } msg]
        borg spinner off
        if {$err} {
            msg -ERROR "DPx_Screen_Saver: import from $browse_dir failed: $msg"
            popup [translate "Could not copy images"]
            return
        }
        apply_saver_dir
        popup "[llength $files] [translate {images set as screen saver}]"
    }

    # Point the core screen saver at our folder, live (no restart needed).
    proc apply_saver_dir {} {
        set root [active_root]
        if {$root eq "" || $::settings(screen_saver_change_interval) == 0} { return }
        set ::saver_directory $root
        unset -nocomplain ::saver_files_cache
    }

    proc message {args} {
        set root [active_root]
        if {$root ne ""} {
            set n [llength [jpgs_in $root/[size_dir]]]
            return "[translate {Screen saver is using}] $n [translate {images from}] [file tail $root]/[size_dir]\r[translate {Pick a folder below to change it. Images should be}] ${::screen_size_width} x ${::screen_size_height} [translate pixels]"
        }
        return "[translate {Pick a folder of .jpg images below, then tap 'Use this folder'.}]\r[translate {Images should be}] ${::screen_size_width} x ${::screen_size_height} [translate pixels]"
    }

    proc check_MySaver_exists {args} {
        set root [active_root]
        if {$root ne ""} {
            set_de1_screen_saver_directory $root
        }
        add_de1_button "saver sleep descaling cleaning" {say [translate {awake}] $::settings(sound_button_in); set_next_page off off; page_show off; start_idle; de1_send_waterlevel_settings; } 0 0 2560 1600
    }

    proc main {} {
        check_MySaver_exists
        plugins gui DPx_Screen_Saver [build_ui]
    }
}
