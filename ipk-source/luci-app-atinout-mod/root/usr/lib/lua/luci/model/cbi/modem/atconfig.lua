local e=require"luci.util"
local o=require"nixio.fs"
local e=require"luci.sys"
local e=require"luci.http"
local e=require"luci.dispatcher"
local e=require"luci.http"
local e=require"luci.sys"
local e=require"luci.model.uci".cursor()
local n="/etc/config/atcommands.user"
local t
local e
local i
local a=nixio.fs.glob("/dev/tty[A-Z][A-Z]*")
t=Map("atinout",translate("Atinout Configuration"),
translate("Configuration panel for atinout."))
e=t:section(NamedSection,'general',"atinout",""..translate("AT Commands Terminal Settings"))
e.anonymous=true
i=e:option(Value,"atcport",translate("AT Command Sending Port"))
if a then
local e
for e in a do
i:value(e,e)
end
end
local e=e:option(TextValue,"user_atcommands",translate("User AT Commands"),translate("Each line must have the following format: 'AT Command name;AT Command'. Save to file '/etc/config/atcommands.user'."))
e.rows=20
e.rmempty=false
function e.cfgvalue(e,e)
return o.readfile(n)
end
function e.write(t,t,e)
e=e:gsub("\r\n","\n")
o.writefile(n,e)
end
return t
