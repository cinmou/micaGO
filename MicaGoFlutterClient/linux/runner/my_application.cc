#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* desktop_channel;
  GtkWindow* main_window;
  GtkWindow* settings_window;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void open_settings_window(MyApplication* self, const gchar* title);

static gchar* pick_contact_file(GtkWindow* parent, const gchar* title) {
  g_autoptr(GtkFileChooserNative) dialog = gtk_file_chooser_native_new(
      title, parent, GTK_FILE_CHOOSER_ACTION_OPEN, nullptr, nullptr);
  gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(dialog), TRUE);
  GtkFileFilter* filter = gtk_file_filter_new();
  gtk_file_filter_set_name(filter, "vCard (*.vcf)");
  gtk_file_filter_add_pattern(filter, "*.vcf");
  gtk_file_filter_add_pattern(filter, "*.VCF");
  gtk_file_filter_add_mime_type(filter, "text/vcard");
  gtk_file_filter_add_mime_type(filter, "text/x-vcard");
  gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(dialog), filter);
  gtk_file_chooser_set_filter(GTK_FILE_CHOOSER(dialog), filter);
  GtkFileFilter* all_files = gtk_file_filter_new();
  gtk_file_filter_set_name(all_files, "All files");
  gtk_file_filter_add_pattern(all_files, "*");
  gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(dialog), all_files);
  const gint response = gtk_native_dialog_run(GTK_NATIVE_DIALOG(dialog));
  return response == GTK_RESPONSE_ACCEPT
             ? gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog))
             : nullptr;
}

static FlValue* pick_files(GtkWindow* parent, const gchar* title) {
  g_autoptr(GtkFileChooserNative) dialog = gtk_file_chooser_native_new(
      title, parent, GTK_FILE_CHOOSER_ACTION_OPEN, nullptr, nullptr);
  gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(dialog), TRUE);
  gtk_file_chooser_set_select_multiple(GTK_FILE_CHOOSER(dialog), TRUE);
  g_autoptr(FlValue) result = fl_value_new_list();
  if (gtk_native_dialog_run(GTK_NATIVE_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
    g_autoptr(GSList) filenames =
        gtk_file_chooser_get_filenames(GTK_FILE_CHOOSER(dialog));
    for (GSList* item = filenames; item != nullptr; item = item->next) {
      g_autofree gchar* path = static_cast<gchar*>(item->data);
      fl_value_append_take(result, fl_value_new_string(path));
    }
  }
  return g_steal_pointer(&result);
}

static gboolean minimize_on_close(GtkWidget* window, GdkEvent*, gpointer) {
  gtk_window_iconify(GTK_WINDOW(window));
  return TRUE;
}

static void quit_action(GSimpleAction*, GVariant*, gpointer application) {
  g_application_quit(G_APPLICATION(application));
}

static void desktop_method_call(FlMethodChannel*, FlMethodCall* call,
                                gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(call);
  if (g_strcmp0(method, "show") == 0) {
    if (self->main_window != nullptr) {
      gtk_window_deiconify(self->main_window);
      gtk_window_present(self->main_window);
    }
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else if (g_strcmp0(method, "openSettings") == 0) {
    if (self->main_window == nullptr) {
      fl_method_call_respond_error(call, "window_unavailable",
                                   "Main window is unavailable", nullptr,
                                   nullptr);
      return;
    }
    FlValue* arguments = fl_method_call_get_args(call);
    FlValue* title = arguments != nullptr &&
                             fl_value_get_type(arguments) == FL_VALUE_TYPE_MAP
                         ? fl_value_lookup_string(arguments, "title")
                         : nullptr;
    open_settings_window(self, title != nullptr && fl_value_get_type(title) ==
                                                       FL_VALUE_TYPE_STRING
                                   ? fl_value_get_string(title)
                                   : "micaGO Settings");
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else if (g_strcmp0(method, "pickContactFile") == 0) {
    GtkWindow* parent = self->settings_window != nullptr ? self->settings_window
                                                         : self->main_window;
    FlValue* arguments = fl_method_call_get_args(call);
    const gchar* title = arguments != nullptr && fl_value_get_type(arguments) ==
                                                     FL_VALUE_TYPE_STRING
                             ? fl_value_get_string(arguments)
                             : "Import contacts";
    g_autofree gchar* path = pick_contact_file(parent, title);
    g_autoptr(FlValue) result =
        path != nullptr ? fl_value_new_string(path) : fl_value_new_null();
    fl_method_call_respond_success(call, result, nullptr);
  } else if (g_strcmp0(method, "pickFiles") == 0) {
    FlValue* arguments = fl_method_call_get_args(call);
    const gchar* title = arguments != nullptr && fl_value_get_type(arguments) ==
                                                     FL_VALUE_TYPE_STRING
                             ? fl_value_get_string(arguments)
                             : "Choose files";
    g_autoptr(FlValue) result = pick_files(self->main_window, title);
    fl_method_call_respond_success(call, result, nullptr);
  } else if (g_strcmp0(method, "closeSettings") == 0) {
    if (self->settings_window != nullptr) {
      gtk_widget_destroy(GTK_WIDGET(self->settings_window));
    }
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else if (g_strcmp0(method, "quit") == 0) {
    fl_method_call_respond_success(call, nullptr, nullptr);
    g_application_quit(G_APPLICATION(self));
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

// FlView configures text input per view. Forward native window focus as well,
// so Flutter restores the correct focus scope when switching between windows.
static void window_focus_changed(GObject* object, GParamSpec*,
                                 gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  GtkWindow* window = GTK_WINDOW(object);
  GtkWidget* child = gtk_bin_get_child(GTK_BIN(window));
  if (self->desktop_channel == nullptr || !FL_IS_VIEW(child)) {
    return;
  }
  g_autoptr(FlValue) arguments = fl_value_new_map();
  fl_value_set_string_take(arguments, "viewId",
                           fl_value_new_int(fl_view_get_id(FL_VIEW(child))));
  fl_value_set_string_take(arguments, "focused",
                           fl_value_new_bool(gtk_window_is_active(window)));
  fl_method_channel_invoke_method(self->desktop_channel, "viewFocus", arguments,
                                  nullptr, nullptr, nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_window_present(GTK_WINDOW(gtk_widget_get_toplevel(GTK_WIDGET(view))));
}

static void main_window_destroyed(GtkWidget*, gpointer user_data) {
  MY_APPLICATION(user_data)->main_window = nullptr;
}

static void settings_window_destroyed(GtkWidget*, gpointer user_data) {
  MY_APPLICATION(user_data)->settings_window = nullptr;
}

static void configure_window(GtkWindow* window, const gchar* title, gint width,
                             gint height) {
  gtk_window_set_title(window, title);
  g_signal_connect_object(
      window, "notify::is-active", G_CALLBACK(window_focus_changed),
      gtk_window_get_application(window), static_cast<GConnectFlags>(0));
  // Keep the icon available when running a relocatable bundle without
  // installing its hicolor theme resources. Wayland taskbars use the matching
  // desktop ID.
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (executable != nullptr) {
    g_autofree gchar* bundle_dir = g_path_get_dirname(executable);
    g_autofree gchar* icon =
        g_build_filename(bundle_dir, "data", "icons", "hicolor", "256x256",
                         "apps", APPLICATION_ID ".png", nullptr);
    if (g_file_test(icon, G_FILE_TEST_IS_REGULAR)) {
      gtk_window_set_icon_from_file(window, icon, nullptr);
    }
  }

  // GNOME uses a GTK header bar. Other desktops (including KDE on Wayland)
  // should keep their window manager's decorations and button placement.
  const gchar* desktop = g_getenv("XDG_CURRENT_DESKTOP");
  g_auto(GStrv) desktops =
      g_strsplit(desktop != nullptr ? desktop : "", ":", -1);
  gboolean use_header_bar = g_strv_contains(desktops, "GNOME");
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, title);
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  }

  gtk_window_set_default_size(window, width, height);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  // Reopening from the launcher should return to the existing conversation.
  if (self->main_window != nullptr) {
    gtk_window_deiconify(self->main_window);
    gtk_window_present(self->main_window);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  self->main_window = window;
  g_signal_connect(window, "destroy", G_CALLBACK(main_window_destroyed), self);
  g_signal_connect(window, "delete-event", G_CALLBACK(minimize_on_close),
                   nullptr);
  configure_window(window, "micaGO", 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->desktop_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "micago/linux_desktop", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->desktop_channel,
                                            desktop_method_call, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// A second view shares the main engine, so preferences and contacts update
// live.
static void open_settings_window(MyApplication* self, const gchar* title) {
  if (self->settings_window != nullptr) {
    gtk_window_deiconify(self->settings_window);
    gtk_window_present(self->settings_window);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(self)));
  self->settings_window = window;
  g_signal_connect(window, "destroy", G_CALLBACK(settings_window_destroyed),
                   self);
  configure_window(window, title, 960, 700);

  FlView* main_view = FL_VIEW(gtk_bin_get_child(GTK_BIN(self->main_window)));
  FlView* view = fl_view_new_for_engine(fl_view_get_engine(main_view));
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));
  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
  g_autoptr(GSimpleAction) quit = g_simple_action_new("quit", nullptr);
  g_signal_connect(quit, "activate", G_CALLBACK(quit_action), application);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(quit));
  const gchar* quit_keys[] = {"<Primary>q", nullptr};
  gtk_application_set_accels_for_action(GTK_APPLICATION(application),
                                        "app.quit", quit_keys);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->desktop_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);
  g_set_application_name("micaGO");
  gtk_window_set_default_icon_name(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(
      my_application_get_type(), "application-id", APPLICATION_ID, nullptr));
}
