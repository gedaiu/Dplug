module plugin;

import std.conv;
import std.process;
import std.string;
import std.file;
import std.regex;
import std.path;
import std.stdio;

import colorize;
import utils;

enum Compiler
{
    ldc,
    gdc,
    dmd,
}

enum Arch
{
    x86,
    x86_64,
    universalBinary
}

Arch[] allArchitectureqForThisPlatform()
{
    Arch[] archs = [Arch.x86, Arch.x86_64];
    version (OSX)
        archs ~= [Arch.universalBinary]; // only Mac has universal binaries
    return archs;
}

string toString(Arch arch)
{
    final switch(arch) with (Arch)
    {
        case x86: return "32-bit";
        case x86_64: return "64-bit";
        case universalBinary: return "Universal-Binary";
    }
}

string toString(Compiler compiler)
{
    final switch(compiler) with (Compiler)
    {
        case dmd: return "dmd";
        case gdc: return "gdc";
        case ldc: return "ldc";
    }
}

string toStringArchs(Arch[] archs)
{
    string r = "";
    foreach(int i, arch; archs)
    {
        final switch(arch) with (Arch)
        {
            case x86:
                if (i) r ~= " and ";
                r ~= "32-bit";
                break;
            case x86_64:
                if (i) r ~= " and ";
                r ~= "64-bit";
                break;
            case universalBinary: break;
        }
    }
    return r;
}

bool configIsVST(string config)
{
    return config.length >= 3 && config[0..3] == "VST";
}

bool configIsAU(string config)
{
    return config.length >= 2 && config[0..2] == "AU";
}

struct Plugin
{
    string name;       // name, extracted from dub.json(eg: 'distort')
    string targetFileName; // result of build
    string copyright;  // Copyright information, copied in the bundle
    string CFBundleIdentifierPrefix;
    string userManualPath; // can be null
    string licensePath;    // can be null
    string iconPath;       // can be null or a path to a (large) .png
    string prettyName;     // Prettier name, extracted from plugin.json (eg: 'My Company Distorter')

    string pluginUniqueID;
    string manufacturerName;
    string manufacturerUniqueID;

    // Public version of the plugin
    // Each release of a plugin should upgrade the version somehow
    int publicVersionMajor;
    int publicVersionMinor;
    int publicVersionPatch;

    string publicVersionString() pure const nothrow
    {
        return to!string(publicVersionMajor) ~ "." ~ to!string(publicVersionMinor) ~ "." ~ to!string(publicVersionMinor);
    }

    string makePkgInfo()
    {
        return "BNDL" ~ manufacturerUniqueID;
    }
}

Plugin readPluginDescription()
{
    Plugin result;
    auto dubResult = execute(["dub", "describe"]);

    if (dubResult.status != 0)
        throw new Exception(format("dub returned %s", dubResult.status));

    import std.json;
    JSONValue description = parseJSON(dubResult.output);

    string mainPackage = description["mainPackage"].str;

    foreach (pack; description["packages"].array())
    {
        string name = pack["name"].str;
        if (name == mainPackage)
        {
            result.name = name;
            result.targetFileName = pack["targetFileName"].str;

            string copyright = pack["copyright"].str;

            if (copyright == "")
            {
                version(OSX)
                {
                    throw new Exception("Your dub.json is missing a non-empty \"copyright\" field to put in Info.plist");
                }
                else
                    writeln("warning: missing \"copyright\" field in dub.json");
            }
            result.copyright = copyright;
        }
    }

    if (!exists("plugin.json"))
    {
        throw new Exception("needs a plugin.json description for proper bundling. Please create one next to dub.json.");
    }

    // Open an eventual plugin.json directly to find keys that DUB doesn't bypass
    JSONValue rawPluginFile = parseJSON(cast(string)(std.file.read("plugin.json")));

    // Optional keys

    // prettyName is the fancy Manufacturer + Product name that will be displayed as much as possible in:
    // - bundle name
    // - renamed executable file names
    try
    {
        result.prettyName = rawPluginFile["prettyName"].str;
    }
    catch(Exception e)
    {
        info("Missing \"prettyName\" in plugin.json (eg: \"My Company Compressor\")\n        => Using dub.json \"name\" key instead.");
        result.prettyName = result.name;
    }

    try
    {
        result.userManualPath = rawPluginFile["userManualPath"].str;
    }
    catch(Exception e)
    {
        info("Missing \"userManualPath\" in plugin.json (eg: \"UserManual.pdf\")");
    }

    try
    {
        result.licensePath = rawPluginFile["licensePath"].str;
    }
    catch(Exception e)
    {
        info("Missing \"licensePath\" in plugin.json (eg: \"license.txt\")");
    }

    try
    {
        result.iconPath = rawPluginFile["iconPath"].str;
    }
    catch(Exception e)
    {
        info("Missing \"iconPath\" in plugin.json (eg: \"gfx/myIcon.png\")");
    }

    // Mandatory keys, but with workarounds

    try
    {
        result.CFBundleIdentifierPrefix = rawPluginFile["CFBundleIdentifierPrefix"].str;
    }
    catch(Exception e)
    {
        warning("Missing \"CFBundleIdentifierPrefix\" in plugin.json (eg: \"com.myaudiocompany\")\n         => Using \"com.totoaudio\" instead.");
        result.CFBundleIdentifierPrefix = "com.totoaudio";
    }

    try
    {
        result.manufacturerName = rawPluginFile["manufacturerName"].str;

    }
    catch(Exception e)
    {
        warning("Missing \"manufacturerName\" in plugin.json (eg: \"Example Corp\")\n         => Using \"Toto Audio\" instead.");
        result.manufacturerName = "Toto Audio";
    }

    try
    {
        result.manufacturerUniqueID = rawPluginFile["manufacturerUniqueID"].str;
    }
    catch(Exception e)
    {
        warning("Missing \"manufacturerUniqueID\" in plugin.json (eg: \"aucd\")\n         => Using \"Toto\" instead.");
        result.manufacturerUniqueID = "Toto";
    }

    if (result.manufacturerUniqueID.length != 4)
        throw new Exception("\"manufacturerUniqueID\" should be a string of 4 characters (eg: \"aucd\")");

    try
    {
        result.pluginUniqueID = rawPluginFile["pluginUniqueID"].str;
    }
    catch(Exception e)
    {
        warning("Missing \"pluginUniqueID\" provided in plugin.json (eg: \"val8\")\n         => Using \"tot0\" instead, change it for a proper release.");
        result.pluginUniqueID = "tot0";
    }

    if (result.pluginUniqueID.length != 4)
        throw new Exception("\"pluginUniqueID\" should be a string of 4 characters (eg: \"val8\")");

        // In developpement, should stay at 0.x.y to avoid various AU caches
    string publicV;
    try
    {
        publicV = rawPluginFile["publicVersion"].str;
    }
    catch(Exception e)
    {
        warning("no \"publicVersion\" provided in plugin.json (eg: \"1.0.1\")\n         => Using \"0.0.0\" instead.");
        publicV = "0.0.0";
    }

    if (auto captures = matchFirst(publicV, regex(`(\d+)\.(\d+)\.(\d+)`)))
    {
        result.publicVersionMajor = to!int(captures[1]);
        result.publicVersionMinor = to!int(captures[2]);
        result.publicVersionPatch = to!int(captures[3]);
    }
    else
    {
        throw new Exception("\"publicVersion\" should follow the form x.y.z with 3 integers (eg: \"1.0.0\")");
    }

    return result;
}


string makePListFile(Plugin plugin, string config, bool hasIcon)
{
    string copyright = plugin.copyright;

    string productVersion = plugin.publicVersionString;
    string content = "";

    content ~= `<?xml version="1.0" encoding="UTF-8"?>` ~ "\n";
    content ~= `<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">` ~ "\n";
    content ~= `<plist version="1.0">` ~ "\n";
    content ~= `    <dict>` ~ "\n";

    void addKeyString(string key, string value)
    {
        content ~= format("        <key>%s</key>\n        <string>%s</string>\n", key, value);
    }

    addKeyString("CFBundleDevelopmentRegion", "English");

    addKeyString("CFBundleGetInfoString", productVersion ~ ", " ~ copyright);

    string CFBundleIdentifier;
    if (configIsVST(config))
        CFBundleIdentifier = plugin.CFBundleIdentifierPrefix ~ ".vst." ~ plugin.name;
    else if (configIsAU(config))
        CFBundleIdentifier = plugin.CFBundleIdentifierPrefix ~ ".audiounit." ~ plugin.name;
    else
        throw new Exception("Configuration name given by --config must start with \"VST\" or \"AU\"");

    //addKeyString("CFBundleName", plugin.prettyName);
    addKeyString("CFBundleIdentifier", CFBundleIdentifier);

    addKeyString("CFBundleVersion", productVersion);
    addKeyString("CFBundleShortVersionString", productVersion);
    //addKeyString("CFBundleExecutable", plugin.prettyName);

    enum isAudioComponentAPIImplemented = false;

    if (isAudioComponentAPIImplemented && configIsAU(config))
    {
        content ~= "        <key>AudioComponents</key>\n";
        content ~= "        <array>\n";
        content ~= "            <dict>\n";
        content ~= "                <key>type</key>\n";
        content ~= "                <string>aufx</string>\n";
        content ~= "                <key>subtype</key>\n";
        content ~= "                <string>dely</string>\n";
        content ~= "                <key>manufacturer</key>\n";
        content ~= "                <string>" ~ plugin.manufacturerUniqueID ~ "</string>\n"; // TODO XML escape that
        content ~= "                <key>name</key>\n";
        content ~= format("                <string>%s</string>\n", plugin.name);
        content ~= "                <key>version</key>\n";
        content ~= "                <integer>0</integer>\n";
        content ~= "                <key>factoryFunction</key>\n";
        content ~= "                <string>dplugAUComponentFactoryFunction</string>\n";
        content ~= "                <key>sandboxSafe</key><true/>\n";
        content ~= "            </dict>\n";
        content ~= "        </array>\n";
    }

    addKeyString("CFBundleInfoDictionaryVersion", "6.0");
    addKeyString("CFBundlePackageType", "BNDL");
    addKeyString("CFBundleSignature", plugin.pluginUniqueID); // doesn't matter http://stackoverflow.com/questions/1875912/naming-convention-for-cfbundlesignature-and-cfbundleidentifier

    addKeyString("LSMinimumSystemVersion", "10.7.0");
   // content ~= "        <key>VSTWindowCompositing</key><true/>\n";

    if (hasIcon)
        addKeyString("CFBundleIconFile", "icon");
    content ~= `    </dict>` ~ "\n";
    content ~= `</plist>` ~ "\n";
    return content;
}


// return path of newly made icon
string makeMacIcon(string pluginName, string pngPath)
{
    string temp = tempDir();
    string iconSetDir = buildPath(tempDir(), pluginName ~ ".iconset");
    string outputIcon = buildPath(tempDir(), pluginName ~ ".icns");

    if(!outputIcon.exists)
    {
        //string cmd = format("lipo -create %s %s -output %s", path32, path64, exePath);
        try
        {
            safeCommand(format("mkdir %s", iconSetDir));
        }
        catch(Exception e)
        {
            cwritefln(" => %s".yellow, e.msg);
        }
        safeCommand(format("sips -z 16 16     %s --out %s/icon_16x16.png", pngPath, iconSetDir));
        safeCommand(format("sips -z 32 32     %s --out %s/icon_16x16@2x.png", pngPath, iconSetDir));
        safeCommand(format("sips -z 32 32     %s --out %s/icon_32x32.png", pngPath, iconSetDir));
        safeCommand(format("sips -z 64 64     %s --out %s/icon_32x32@2x.png", pngPath, iconSetDir));
        safeCommand(format("sips -z 128 128   %s --out %s/icon_128x128.png", pngPath, iconSetDir));
        safeCommand(format("sips -z 256 256   %s --out %s/icon_128x128@2x.png", pngPath, iconSetDir));
        safeCommand(format("iconutil --convert icns --output %s %s", outputIcon, iconSetDir));
    }
    return outputIcon;
}

string makeRSRC(Plugin plugin, Arch arch, bool verbose)
{
    string pluginName = plugin.name;
    cwritefln("*** Generating a .rsrc file for the bundle...".white);
    string temp = tempDir();

    string rPath = buildPath(temp, "plugin.r");

    File rFile = File(rPath, "w");
    static immutable string rFileBase = cast(string) import("plugin-base.r");

    string plugVer = to!string((plugin.publicVersionMajor << 16) | (plugin.publicVersionMinor << 8) | plugin.publicVersionPatch);

    rFile.writefln(`#define PLUG_NAME "%s"`, pluginName); // no escaping there, TODO
    rFile.writefln("#define PLUG_MFR_ID '%s'", plugin.manufacturerUniqueID);
    rFile.writefln("#define PLUG_VER %s", plugVer);
    rFile.writefln("#define PLUG_UNIQUE_ID '%s'", plugin.pluginUniqueID);

    rFile.writeln(rFileBase);
    rFile.close();

    string rsrcPath = buildPath(temp, "plugin.rsrc");

    string archFlags;
    final switch(arch) with (Arch)
    {
        case x86: archFlags = "-arch i386"; break;
        case x86_64: archFlags = "-arch x86_64"; break;
        case universalBinary: archFlags = "-arch i386 -arch x86_64"; break;
    }

    string verboseFlag = verbose ? " -p" : "";
    /* -t BNDL */
    safeCommand(format("rez %s%s -o %s -useDF %s", archFlags, verboseFlag, rsrcPath, rPath));


    if (!exists(rsrcPath))
        throw new Exception(format("%s wasn't created", rsrcPath));

    if (getSize(rsrcPath) == 0)
        throw new Exception(format("%s is an empty file", rsrcPath));

    cwritefln("    => Written %s bytes.".green, getSize(rsrcPath));
    cwriteln();
    return rsrcPath;
}