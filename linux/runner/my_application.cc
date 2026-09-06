#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

#ifndef NDEBUG
// `flutter run` launches the bundle directly, so GNOME has no installed
// desktop file to associate with the Wayland application ID. Register a
// development desktop entry using the exact application ID and an absolute
// icon path, following the same strategy used by Plume PDF.
static void copy_file_overwrite(const gchar* source_path,
                                const gchar* target_path) {
  g_autoptr(GError) error = nullptr;
  g_autofree gchar* target_dir = g_path_get_dirname(target_path);
  g_mkdir_with_parents(target_dir, 0755);

  g_autoptr(GFile) source = g_file_new_for_path(source_path);
  g_autoptr(GFile) target = g_file_new_for_path(target_path);
  g_file_copy(source, target, G_FILE_COPY_OVERWRITE, nullptr, nullptr, nullptr,
              &error);
  if (error != nullptr) {
    g_warning("Failed to copy %s to %s: %s", source_path, target_path,
              error->message);
  }
}

static void install_dev_desktop_entry(const gchar* exe_path,
                                      const gchar* icon_path) {
  const gchar* user_data_dir = g_get_user_data_dir();
  g_autofree gchar* applications_dir =
      g_build_filename(user_data_dir, "applications", nullptr);
  g_autofree gchar* desktop_path = g_build_filename(
      applications_dir, "com.github.xiehanff.hax_shot.desktop", nullptr);

  g_autofree gchar* desktop_contents = g_strdup_printf(
      "[Desktop Entry]\n"
      "Type=Application\n"
      "Name=Hax Shot\n"
      "Exec=%s\n"
      "Icon=%s\n"
      "Terminal=false\n"
      "NoDisplay=false\n"
      "Categories=Graphics;Utility;\n"
      "StartupNotify=true\n"
      "StartupWMClass=com.github.xiehanff.hax_shot\n"
      "X-GNOME-WMClass=com.github.xiehanff.hax_shot\n",
      exe_path, icon_path);

  g_mkdir_with_parents(applications_dir, 0755);
  g_file_set_contents(desktop_path, desktop_contents, -1, nullptr);
}
#endif

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
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
    gtk_header_bar_set_title(header_bar, "Hax Shot");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Hax Shot");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  // Set the GTK window icon from the bundle. The icon is installed beside
  // flutter_assets by CMake, so this works with both `flutter run` and a
  // release bundle before any system-wide installation takes place.
  const gchar* assets_dir = fl_dart_project_get_assets_path(project);
  g_autofree gchar* data_dir = g_path_get_dirname(assets_dir);
  g_autofree gchar* icon_path =
      g_build_filename(data_dir, "hax_shot_icon.png", nullptr);
  gtk_window_set_icon_from_file(window, icon_path, nullptr);
  gtk_window_set_icon_name(window, APPLICATION_ID);

#ifndef NDEBUG
  // Make `flutter run` visible in the GNOME dock with the correct icon.
  g_autofree gchar* exe_path = g_file_read_link("/proc/self/exe", nullptr);
  if (exe_path != nullptr) {
    const gchar* user_data_dir = g_get_user_data_dir();
    g_autofree gchar* icon_dir = g_build_filename(
        user_data_dir, "icons", "hicolor", "256x256", "apps", nullptr);
    g_autofree gchar* user_icon_path = g_build_filename(
        icon_dir, "com.github.xiehanff.hax_shot.png", nullptr);
    copy_file_overwrite(icon_path, user_icon_path);
    install_dev_desktop_entry(exe_path, user_icon_path);
  }
#endif

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // The Dart side controls visibility. The normal process is tray-only, while
  // a capture process shows this window only after the frozen frame is ready.
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

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

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
