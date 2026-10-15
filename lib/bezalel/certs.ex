defmodule Bezalel.Certs do
  @moduledoc """
  Loads the Mozilla CA bundle into `:public_key` before any HTTPS call
  (sign-in token exchange, model calls). A phone has no CA store where OTP's
  `:public_key.cacerts_load/0` looks, so the first TLS connect would fail.
  The bundle is castore's PEM, embedded at compile time (deps' `priv/`
  isn't shipped to the device), written to the cache dir and loaded with
  `Mob.Certs.load_cacerts!/1`, as Operator does.
  """

  @cacerts_path Path.expand(Path.join([__DIR__, "../..", "deps/castore/priv/cacerts.pem"]))
  @external_resource @cacerts_path
  @cacerts_pem File.read!(@cacerts_path)

  @spec install!() :: :ok
  def install! do
    # Not System.tmp_dir!/0: Android's app sandbox has no writable TMPDIR.
    path = Path.join(Mob.Storage.dir(:cache), "bezalel_cacerts.pem")
    File.write!(path, @cacerts_pem)
    Mob.Certs.load_cacerts!(path)
  end
end
