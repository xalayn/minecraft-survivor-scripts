-- Teams module, server side: requests for the control app (see lib/teams.lua).

local teams = require("teams")

return {
  title = "Teams",
  handlers = {
    list = teams.list,
    get = teams.get,
    create = teams.create,
    set = teams.set,
    delete = teams.delete,
    join = teams.join,
    leave = teams.leave,
    empty = teams.empty,
    options = teams.options,
  },
}
