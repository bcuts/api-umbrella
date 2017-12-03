local build_url = require "api-umbrella.utils.build_url"
local deep_merge_overwrite_arrays = require "api-umbrella.utils.deep_merge_overwrite_arrays"
local http = require "resty.http"
local is_empty = require("pl.types").is_empty
local json_decode = require("cjson").decode
local random_token = require "api-umbrella.utils.random_token"
local t = require("api-umbrella.web-app.utils.gettext").gettext

local _M = {}

local function redirect_uri(strategy_name)
  local url_name = strategy_name
  if strategy_name == "google" then
    url_name = "google_oauth2"
  end

  return build_url("/admins/auth/" .. url_name .. "/callback")
end

local function get_token(httpc, code, strategy_name, options)
  if is_empty(code) then
    ngx.log(ngx.ERR, "oauth2 missing code")
    return nil, t("Authorization failed")
  end

  if config["app_env"] == "test" and ngx.var.cookie_test_mock_userinfo then
    return "mock_test_token"
  end

  local res, err = httpc:request_uri(assert(options["token_endpoint"]), {
    method = "POST",
    headers = {
      ["Accept"] = "application/json",
      ["Content-Type"] = "application/x-www-form-urlencoded",
    },
    body = ngx.encode_args({
      code = code,
      client_id = config["web"]["admin"]["auth_strategies"][strategy_name]["client_id"],
      client_secret = config["web"]["admin"]["auth_strategies"][strategy_name]["client_secret"],
      redirect_uri = redirect_uri(strategy_name),
      grant_type = "authorization_code",
    }),
    query = options["token_query_params"],
  })
  if err then
    ngx.log(ngx.ERR, "oauth2 token error: ", err)
    return nil, t("Authorization failed")
  elseif res.status >= 500 then
    ngx.log(ngx.ERR, "oauth2 token error response (" .. res.status .. "): " .. (res.body or ""))
    return nil, t("Authorization failed")
  elseif res.status >= 400 then
    ngx.log(ngx.WARN, "oauth2 token denied response (" .. res.status .. "): " .. (res.body or ""))
    return nil, t("Authorization denied")
  end

  local data = json_decode(res.body)
  if data and data["access_token"] then
    return data["access_token"]
  else
    ngx.log(ngx.ERR, "oauth2 token missing from response (" .. res.status .. "): " .. (res.body or ""))
    return nil, t("Authorization denied")
  end
end

local function parse_userinfo(body)
  return json_decode(body)
end

local function get_userinfo(httpc, token, options)
  if config["app_env"] == "test" and ngx.var.cookie_test_mock_userinfo then
    local mock_userinfo = require "api-umbrella.web-app.utils.test_env_mock_userinfo"
    return parse_userinfo(mock_userinfo())
  end

  local res, err = httpc:request_uri(assert(options["userinfo_endpoint"]), {
    headers = {
      ["Accept"] = "application/json",
      ["Authorization"] = "Bearer " .. token,
    },
    query = options["userinfo_query_params"],
  })
  if err then
    ngx.log(ngx.ERR, "oauth2 userinfo error: ", err)
    return nil, t("Authorization failed")
  elseif res.status >= 500 then
    ngx.log(ngx.ERR, "oauth2 userinfo error response (" .. res.status .. "): " .. (res.body or ""))
    return nil, t("Authorization failed")
  elseif res.status >= 400 then
    ngx.log(ngx.WARN, "oauth2 userinfo denied response (" .. res.status .. "): " .. (res.body or ""))
    return nil, t("Authorization denied")
  end

  return parse_userinfo(res.body)
end

function _M.authorize(self, strategy_name, url, params)
  local state = random_token(64)
  self:init_session_cookie()
  self.session_cookie:start()
  self.session_cookie.data["oauth2_state"] = state
  self.session_cookie:save()

  local callback_url = redirect_uri(strategy_name)
  local redirect = url .. "?" .. ngx.encode_args(deep_merge_overwrite_arrays({
    client_id = config["web"]["admin"]["auth_strategies"][strategy_name]["client_id"],
    response_type = "code",
    scope = "read_user",
    redirect_uri = callback_url,
    state = state,
  }, params))

  if config["app_env"] == "test" and ngx.var.cookie_test_mock_userinfo then
    redirect = callback_url .. "?" .. ngx.encode_args({
      state = state,
      code = "mock_test_code",
    })
  end

  return { redirect_to = redirect }
end

function _M.userinfo(self, strategy_name, options)
  self:init_session_cookie()
  self.session_cookie:open()
  if not self.session_cookie or not self.session_cookie.data or not self.session_cookie.data["oauth2_state"] then
    ngx.log(ngx.ERR, "oauth2 state not available")
    return nil, t("Cross-site request forgery detected")
  end

  local stored_state = self.session_cookie.data["oauth2_state"]
  local state = self.params["state"]
  if state ~= stored_state then
    ngx.log(ngx.ERR, "oauth2 state does not match")
    return nil, t("Cross-site request forgery detected")
  end

  local httpc = http.new()
  local token, err = get_token(httpc, self.params["code"], strategy_name, options)
  if not token then
    return nil, err
  end

  return get_userinfo(httpc, token, options)
end

return _M