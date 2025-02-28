# KOReader Pocketbook Sync

A KOReader plugin that syncs reading progress from KOReader to PocketBook
Library, primarily to make the book progress bars on PocketBook's home screen
accurate.

## Installation

Copy the folder *pocketbooksync.koplugin* to */applications/koreader/plugins* on your PocketBook device.\
Please mind to keep the folder name as it is.

## Usage

After you've installed the KOReader plugin, syncing will happen silently with each page update.

Note that the sync is only one way (from KOReader), and it only syncs the
progress bars to Library. It is not meant to sync the reading position between
KOReader and PBReader.

For further information, read the corresponding thread on MobileRead:
https://www.mobileread.com/forums/showthread.php?t=354026

## Automatically remove from selected collection
For example, if you (like me) add books to your "to read" collection and then remove them from that collection after reading, the plugin will help automate this. You must specify the name of the selected collection in the plugin settings.
