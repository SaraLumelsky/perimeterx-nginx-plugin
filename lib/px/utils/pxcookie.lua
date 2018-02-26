local PXPayload = require "px.utils.pxpayload"

PXCookie = PXPayload:new{}

function PXCookie:new(t)
    t = t or {}
    setmetatable(t, self)
    self.__index = self
    return t
end

function PXCookie:process()
    cookie = ngx.ctx.px_orig_cookie
    if not cookie then
        error({ message = "no_cookie" })
    end
end

return PXCookie