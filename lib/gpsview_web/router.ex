defmodule GPSViewWeb.Router do
  use GPSViewWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
  end

  scope "/", GPSViewWeb do
    pipe_through :browser
    get "/", PageController, :index
  end

  scope "/api", GPSViewWeb do
    pipe_through :api

    resources "/devices", DeviceController, only: [:index, :show]
    get "/devices/:id/tracks", TrackController, :index
    get "/tracks/:id", TrackController, :show
    get "/fixes", FixController, :index
    post "/ingest", IngestController, :create
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:gpsview, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: GPSViewWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
