# Plugin Lists Creator

This plugin is intended to create shelves dynamically from an excel file

# Requirements

- Koha mininum version: 18.11
- Perl modules:
    - JavaScript::Minifier
    - Spreadsheet::Read
    - Spreadsheet::XLSX
    - File::Copy
    - File::Temp
    - File::Basename
    - Text::CSV::Encoded

# Installation

Download the package file ListsCreator.kpz

Login to Koha Admin and go to the plugin screen

Upload Plugin

# Configuration

In the configuration page, you can:
- Enable the plugin
- Establish the defaults for a new shelf creation.

# Documentation

Run the tool and upload an excel file to create or update an existing shelf.

To create those lists,  you must have to download this template, and fill it.

[Download the excel template](doc/template.xlsx)

To create lists en batch mode,  you have  to upload the Excel files to 
```
[your_plugin_dir]/Koha/Plugin/Es/Xercode/BatchUploadDir/
```
