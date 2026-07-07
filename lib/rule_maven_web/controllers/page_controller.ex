defmodule RuleMavenWeb.PageController do
  use RuleMavenWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def help(conn, _params) do
    render(conn, :help, page_title: "Help")
  end
end
