local Device = require("device")

if not Device:isPocketBook() then
    return { disabled = true, }
end

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local logger = require("logger")
local util = require("util")
local SQ3 = require("lua-ljsqlite3/init")
local pocketbookDbConn = SQ3.open("/mnt/ext1/system/explorer-3/explorer-3.db")
local ffi = require("ffi")
local inkview = ffi.load("inkview")
local bookIds = {}
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")

pocketbookDbConn:exec("PRAGMA journal_mode=WAL;")

local PocketbookSync = WidgetContainer:extend{
    name = "pocketbooksync",
    is_doc_only = false,
}

function PocketbookSync:init()
    self.ui.menu:registerToMainMenu(self)
end

local collection_info_text = _([[
The function allows you to automatically remove a book from a specified collection after reading it.]])

local about_text = _([[
A KOReader plugin that syncs reading progress from KOReader to PocketBook Library, primarily to make the book progress bars on PocketBook's home screen accurate.

If you want the book to be automatically removed from a specific collection after reading, set the collection name in the settings.]])

function PocketbookSync:addToMainMenu(menu_items)
    menu_items.pocketbook_sync = {
		sorting_hint = "tools",
        text = _("PocketBook Sync"),
        sub_item_table = {
			{
                text = _("About Pocketbook Sync"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = about_text,
                    })
                end,
                keep_menu_open = true,
                separator = true,
            },
            {
                text = _("Collection Name"),
                callback = function()
                    self:setCollection()
                end,
				help_text = collection_info_text,
            },
        }
    }
end

function PocketbookSync:getCollectionIdByName(name)
    if not name or name == "" then
        return nil
    end
    
    local stmt = pocketbookDbConn:prepare("SELECT id FROM bookshelfs WHERE name = ? AND is_deleted != 1 LIMIT 1")
    local row = stmt:reset():bind(name):step()
    stmt:close()
    
    if row == nil then
        logger.info("Pocketbook Sync: Collection '" .. name .. "' not found")
        return nil
    end
    
	local id_str = tostring(row[1]):gsub("LL$", "")
	local id_num = tonumber(id_str)
	if not id_num then
		logger.warn("Pocketbook Sync: Failed to convert collection ID to number, value: " .. tostring(id_str))
		return nil
	end
    logger.info("Pocketbook Sync: Collection ID found: " .. tostring(id_num))
    
    return id_num
end

function PocketbookSync:setCollection()
    local collection_name_dialog
    collection_name_dialog = InputDialog:new{
        title = _("Set Collection Name"),
        input = G_reader_settings:readSetting("to_read_collection_name") or "",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(collection_name_dialog)
                end,
            },
            {
                text = _("Set Name"),
                callback = function()
                    local name = collection_name_dialog:getInputText()
                    if name and name ~= "" then
                        local status, err = pcall(function()
                            G_reader_settings:saveSetting("to_read_collection_name", name)
                            G_reader_settings:flush()
                            
                            local collection_id = self:getCollectionIdByName(name)
                            if collection_id then
                                G_reader_settings:saveSetting("to_read_collection_id", collection_id)
                                G_reader_settings:flush()
                                logger.info("Pocketbook Sync: Collection ID saved: " .. tostring(collection_id))
                            else
                                logger.info("Pocketbook Sync: Collection ID not found for '" .. name .. "'")
                                G_reader_settings:delSetting("to_read_collection_id")
                                G_reader_settings:flush()
                            end
                        end)
                        
                        if not status then
                            logger.warn("Pocketbook Sync: Error saving settings: " .. tostring(err))
                        end
                    else
                        G_reader_settings:delSetting("to_read_collection_name")
                        G_reader_settings:delSetting("to_read_collection_id")
                        G_reader_settings:flush()
                    end
                    UIManager:close(collection_name_dialog)
                end,
            },
        }},
    }
    UIManager:show(collection_name_dialog)
    collection_name_dialog:onShowKeyboard()
end

function PocketbookSync:saveCollectionSettings(name)
    local collection_id = self:getCollectionIdByName(name)
    
    G_reader_settings:saveSetting("to_read_collection_name", name)
    G_reader_settings:flush()
    
    if collection_id then
        G_reader_settings:saveSetting("to_read_collection_id", collection_id)
        logger.info("Pocketbook Sync: Collection ID saved: " .. collection_id)
        G_reader_settings:flush()
    else
        logger.info("Pocketbook Sync: Collection ID not found for '" .. name .. "'")
        G_reader_settings:delSetting("to_read_collection_id")
        G_reader_settings:flush()
    end
    
    local saved_id = G_reader_settings:readSetting("to_read_collection_id")
    logger.info("Pocketbook Sync: Verification - saved ID: " .. tostring(saved_id))
end

function PocketbookSync:deleteCollectionSettings()
    local success = pcall(function()
        G_reader_settings:delSetting("to_read_collection_name")
        G_reader_settings:delSetting("to_read_collection_id")
    end)
    
    if not success then
        logger.error("Pocketbook Sync: Failed to delete collection settings")
    end
    
    G_reader_settings:flush()
end

pocketbookDbConn:set_busy_timeout(1000)

local function GetCurrentProfileId()
    local profile_name = inkview.GetCurrentProfile()
    if profile_name == nil then
        return 1
    else
        local stmt = pocketbookDbConn:prepare("SELECT id FROM profiles WHERE name = ?")
        local profile_id = stmt:reset():bind(ffi.string(profile_name)):step()
        stmt:close()
        return profile_id[1]
    end
end

local profile_id = GetCurrentProfileId()

function PocketbookSync:clearCache()
    bookIds = {}
end

function PocketbookSync:sync()
    self:doSync(self:prepareSync())
end

function PocketbookSync:prepareSync()
    -- onFlushSettings called during koreader exit and after onCloseDocument
    -- would raise an error in some of the self.document methods and we can
    -- avoid that by checking if self.ui.document is nil
    if not self.ui.document then
        return nil
    end

    local folder, file = self:getFolderFile()
    if not folder or folder == "" or not file or file == "" then
        logger.info("Pocketbook Sync: No folder/file found for " .. self.view.document.file)
        return nil
    end

    local globalPage = self.view.state.page
    local flow = self.document:getPageFlow(globalPage)

    -- skip sync if not in the main flow
    if flow ~= 0 then
        return nil
    end

    local totalPages = self.document:getTotalPagesInFlow(flow)
    local page = self.document:getPageNumberInFlow(globalPage)

    local summary = self.ui.doc_settings:readSetting("summary")
    local status = summary and summary.status
    local completed = (status == "complete" or page == totalPages) and 1 or 0

    -- hide the progress bar if we're on the title/cover page
    --
    -- we'll never set cpage=1 so the progress bar will seem to jump a bit at
    -- the start of a book, but there's no nice way to fix that: to use the
    -- full range, we'd need to map pages 2 to last-1 to cpages 1 to last-1,
    -- and that always skips one position; skipping the first one is the least
    -- surprising behaviour
    if page == 1 then
        page = 0
    end

    return {
        folder = folder,
        file = file,
        totalPages = totalPages,
        page = page,
        completed = completed,
        time = os.time(),
    }
end

function PocketbookSync:doSync(data)
    if not data then
        return
    end

    local cacheKey = data.folder .. data.file

    if not bookIds[cacheKey] then
        local sql = [[
            SELECT book_id
            FROM files
            WHERE
                folder_id = (SELECT id FROM folders WHERE name = ? LIMIT 1)
            AND filename = ?
            LIMIT 1
        ]]
        local stmt = pocketbookDbConn:prepare(sql)
        local row = stmt:reset():bind(data.folder, data.file):step()
        stmt:close()

        if row == nil then
            logger.info("Pocketbook Sync: Book id for " .. data.folder .. "/" .. data.file .. " not found")
            return
        end
        bookIds[cacheKey] = row[1]
    end

    local book_id = bookIds[cacheKey]
    local sql = [[
            REPLACE INTO books_settings
            (bookid, profileid, cpage, npage, completed, opentime)
            VALUES (?, ?, ?, ?, ?, ?)
        ]]
    local stmt = pocketbookDbConn:prepare(sql)
    stmt:reset():bind(book_id, profile_id, data.page, data.totalPages, data.completed, data.time):step()
    stmt:close()

    -- Если книга отмечена как прочитанная, проверяем таблицу bookshelfs_books и удаляем запись, если bookshelfid совпадает с сохранённым id
    if data.completed == 1 then
        local collection_id = G_reader_settings:readSetting("to_read_collection_id")
        if collection_id and collection_id ~= "" then
            collection_id = tonumber(collection_id)
			logger.info("Collection ID", collection_id)
            local check_sql = "SELECT bookshelfid FROM bookshelfs_books WHERE bookid = ? AND bookshelfid = ? LIMIT 1"
            local check_stmt = pocketbookDbConn:prepare(check_sql)
            local check_row = check_stmt:reset():bind(book_id, collection_id):step()
            check_stmt:close()
            if check_row then
                local del_sql = "DELETE FROM bookshelfs_books WHERE bookid = ? AND bookshelfid = ?"
                local del_stmt = pocketbookDbConn:prepare(del_sql)
                del_stmt:reset():bind(book_id, collection_id):step()
                del_stmt:close()
            end
        end
    end
end

function PocketbookSync:getFolderFile()
    local path = self.view.document.file
    local folder, file = util.splitFilePathName(path)
    local folderTrimmed = folder:match("(.*)/")
    if folderTrimmed ~= nil then
        folder = folderTrimmed
    end
    return folder, file
end

function PocketbookSync:onFlushSettings()
    self:sync()
end

function PocketbookSync:onCloseDocument()
    self:sync()
end

function PocketbookSync:onEndOfBook()
    self:sync()
	logger.info("End of Book")
end

function PocketbookSync:onSuspend()
    self:sync()
end

return PocketbookSync
