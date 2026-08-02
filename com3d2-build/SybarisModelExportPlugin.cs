using COM3D2.ModelExportMMD.Extensions;
using COM3D2.ModelExportMMD.Gui;
using System;
using System.IO;
using System.Linq;
using System.Windows.Forms;
using UnityEngine;
using UnityInjector;
using UnityInjector.Attributes;

namespace COM3D2.ModelExportMMD.Plugin
{
    [PluginName("COM3D2 Model Export to MMD Fixed")]
    [PluginVersion("3.1-SYB-R2")]
    [PluginFilter("COM3D2OHx64")]
    [PluginFilter("COM3D2VRx64")]
    [PluginFilter("COM3D2OHVRx64")]
    [PluginFilter("COM3D2x64")]
    public class ModelExportPlugin : PluginBase
    {
        private const string IniSection = "ExportPreferences";
        private const string IniKeyFolderPath = "FolderPath";
        private const string IniKeyFormat = "Format";
        private const string IniKeySavePosition = "SavePosition";
        private const string IniKeySaveTextures = "SaveTextures";
        private ModelExportWindow window;

        public void Update()
        {
            if (Input.GetKeyDown(KeyCode.F8))
            {
                EnsureWindow();
                window.Show();
            }
        }

        public void OnGUI()
        {
            EnsureWindow();
            window.DrawWindow();
        }

        private void EnsureWindow()
        {
            if (window != null) return;
            window = new ModelExportWindow()
            {
                PluginVersion = ((PluginVersionAttribute)GetType().GetCustomAttributes(typeof(PluginVersionAttribute), false)[0]).Version,
                ExportFolderPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Maids"),
                ExportName = "Maid",
                ExportClass = ModelExportEventArgs.ExporterClass.PmxA,
                SavePostion = true,
                SaveTextures = true,
            };
            window.BrowseClicked += BrowseForExportFolder;
            window.ApplyTPoseClicked += ApplyTPose;
            window.ExportClicked += ExportModel;
            window.CloseClicked += delegate(object s, EventArgs a) { SaveUserPreferences(); };
            LoadUserPreferences();
        }

        private void LoadUserPreferences()
        {
            try
            {
                var section = Preferences.GetSection(IniSection);
                if (section == null) return;
                var folder = section.GetKey(IniKeyFolderPath);
                if (folder != null && !string.IsNullOrEmpty(folder.RawValue)) window.ExportFolderPath = folder.RawValue;
                var format = section.GetKey(IniKeyFormat);
                if (format != null && !string.IsNullOrEmpty(format.RawValue))
                {
                    try
                    {
                        window.ExportClass = (ModelExportEventArgs.ExporterClass)Enum.Parse(typeof(ModelExportEventArgs.ExporterClass), format.RawValue, true);
                        if (window.ExportClass == ModelExportEventArgs.ExporterClass.PmxB)
                        {
                            window.ExportClass = ModelExportEventArgs.ExporterClass.PmxA;
                        }
                    }
                    catch
                    {
                        window.ExportClass = ModelExportEventArgs.ExporterClass.PmxA;
                    }
                }
                bool value;
                var savePosition = section.GetKey(IniKeySavePosition);
                if (savePosition != null && bool.TryParse(savePosition.RawValue, out value)) window.SavePostion = value;
                var saveTextures = section.GetKey(IniKeySaveTextures);
                if (saveTextures != null && bool.TryParse(saveTextures.RawValue, out value)) window.SaveTextures = value;
            }
            catch (Exception error)
            {
                Debug.LogError("Error loading exporter preferences: " + error.Message + "\n\nStack trace:\n" + error.StackTrace);
            }
        }

        private void SaveUserPreferences()
        {
            try
            {
                var section = Preferences.CreateSection(IniSection);
                section.CreateKey(IniKeyFolderPath).Value = window.ExportFolderPath;
                section.CreateKey(IniKeyFormat).Value = window.ExportClass.ToString();
                section.CreateKey(IniKeySavePosition).Value = window.SavePostion.ToString();
                section.CreateKey(IniKeySaveTextures).Value = window.SaveTextures.ToString();
                SaveConfig();
            }
            catch (Exception error)
            {
                Debug.LogError("Error saving exporter preferences: " + error.Message + "\n\nStack trace:\n" + error.StackTrace);
            }
        }

        private void BrowseForExportFolder(object sender, EventArgs args)
        {
            var dialog = new SaveFileDialog();
            dialog.Title = "Select the folder where the model and textures will be exported";
            dialog.Filter = window.ExportClass == ModelExportEventArgs.ExporterClass.Obj
                ? "Wavefront (*.obj)|*.obj|All files (*.*)|*.*"
                : "MikuMikuDance (*.pmx)|*.pmx|All files (*.*)|*.*";
            dialog.FileName = window.ExportName;
            dialog.InitialDirectory = window.ExportFolderPath;
            if (!Directory.Exists(dialog.InitialDirectory)) dialog.InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
            if (dialog.ShowDialog() == DialogResult.OK)
            {
                window.ExportFolderPath = Path.GetDirectoryName(dialog.FileName);
                window.ExportName = Path.GetFileNameWithoutExtension(dialog.FileName);
            }
        }

        private void ApplyTPose(object sender, EventArgs args)
        {
            try
            {
                GameMain.Instance.CharacterMgr.GetMaid(0).ApplyTPose();
            }
            catch (Exception error)
            {
                Debug.LogError("Error applying T-pose: " + error.Message + "\n\nStack trace:\n" + error.StackTrace);
            }
        }

        private void ExportModel(object sender, ModelExportEventArgs args)
        {
            try
            {
                SaveUserPreferences();
                var meshes = FindObjectsOfType<SkinnedMeshRenderer>()
                    .Where(smr => smr.name != "obj1" && smr.name != "moza")
                    .Distinct()
                    .ToList();

                IExporter exporter;
                switch (args.Exporter)
                {
                    case ModelExportEventArgs.ExporterClass.Obj:
                        exporter = new ObjExporter();
                        break;
                    case ModelExportEventArgs.ExporterClass.PmxA:
                    case ModelExportEventArgs.ExporterClass.PmxB:
                        exporter = new PmxExporter();
                        break;
                    default:
                        throw new Exception("Unknown model format: " + args.Exporter);
                }

                exporter.ExportFolder = args.Folder;
                exporter.ExportName = args.Name;
                exporter.SavePosition = args.SavePosition;
                exporter.SaveTexture = args.SaveTexture;
                exporter.Export(meshes);
            }
            catch (Exception error)
            {
                Debug.LogError("Error exporting model: " + error.Message + "\n\nStack trace:\n" + error.StackTrace);
            }
        }
    }
}
