// Launcher.cs
//
// Kleines Startprogramm, das bei der Installation mit dem C#-Compiler
// uebersetzt wird, der in Windows bereits enthalten ist (csc.exe aus dem
// .NET Framework) - es wird also nichts heruntergeladen.
//
// Ohne Argument oeffnet es das Programmfenster, mit einem Profilnamen
// schaltet es direkt um:
//     PowerProfileSwitcher.exe            -> Fenster
//     PowerProfileSwitcher.exe Travel     -> Profil "Unterwegs"
//
// Der Installationspfad wird beim Uebersetzen eingesetzt, damit die EXE
// auch funktioniert, wenn sie auf dem Desktop liegt.

using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

public class Launcher
{
    private const string InstallDir = @"__INSTALL_DIR__";

    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            if (args.Length > 0 && args[0].Length > 0)
            {
                // Profil direkt umschalten - laeuft ueber die geplante
                // Aufgabe, damit keine Rechteabfrage noetig ist.
                ProcessStartInfo task = new ProcessStartInfo(
                    "schtasks.exe",
                    "/run /tn \"PowerProfileSwitcher-" + args[0] + "\"");
                task.UseShellExecute = false;
                task.CreateNoWindow = true;
                Process.Start(task);
                return 0;
            }

            string script = Path.Combine(InstallDir, "Show-PowerWindow.ps1");
            if (!File.Exists(script))
            {
                MessageBox.Show(
                    "Die App wurde nicht gefunden:\n" + script +
                    "\n\nBitte Install.ps1 erneut ausfuehren.",
                    "PowerProfile Switcher",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return 1;
            }

            ProcessStartInfo window = new ProcessStartInfo(
                "powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"");
            window.UseShellExecute = false;
            window.CreateNoWindow = true;
            Process.Start(window);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("Start fehlgeschlagen:\n" + ex.Message,
                "PowerProfile Switcher",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
