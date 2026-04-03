defmodule SpectreKinetic.TestRegistryHelper do
  @moduledoc false

  def registry_json(actions \\ base_actions()) do
    path =
      Path.join(System.tmp_dir!(), "spectre_registry_#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(%{"actions" => actions}))
    path
  end

  def base_actions do
    [
      %{
        "id" => "Linux.Apt.install/1",
        "module" => "Linux.Apt",
        "name" => "install",
        "arity" => 1,
        "doc" => "Install a Linux package with APT",
        "spec" => "install(package :: String.t()) :: :ok",
        "args" => [
          %{
            "name" => "package",
            "type" => "String.t()",
            "required" => true,
            "aliases" => ["pkg"]
          }
        ],
        "examples" => [
          "INSTALL PACKAGE WITH: PACKAGE=\"nginx\"",
          "INSTALL PACKAGE nginx VIA APT"
        ]
      },
      %{
        "id" => "Linux.Dnf.install/1",
        "module" => "Linux.Dnf",
        "name" => "install",
        "arity" => 1,
        "doc" => "Install a Linux package with DNF",
        "spec" => "install(package :: String.t()) :: :ok",
        "args" => [
          %{
            "name" => "package",
            "type" => "String.t()",
            "required" => true,
            "aliases" => ["pkg"]
          }
        ],
        "examples" => [
          "INSTALL PACKAGE WITH: PACKAGE=\"htop\" VIA DNF",
          "INSTALL PACKAGE htop VIA DNF"
        ]
      },
      %{
        "id" => "Linux.Coreutils.ls/1",
        "module" => "Linux.Coreutils",
        "name" => "ls",
        "arity" => 1,
        "doc" => "List a directory path",
        "spec" => "ls(path :: String.t()) :: [String.t()]",
        "args" => [
          %{
            "name" => "path",
            "type" => "String.t()",
            "required" => true,
            "aliases" => ["dir", "directory"]
          }
        ],
        "examples" => [
          "LIST DIRECTORY WITH: PATH=\"/var/log\"",
          "LIST DIRECTORY /tmp"
        ]
      },
      %{
        "id" => "Elchemista.Blog.create_post/2",
        "module" => "Elchemista.Blog",
        "name" => "create_post",
        "arity" => 2,
        "doc" => "Write a new blog post for elchemista.com",
        "spec" => "create_post(title :: String.t(), body :: String.t()) :: :ok",
        "args" => [
          %{
            "name" => "title",
            "type" => "String.t()",
            "required" => true,
            "aliases" => ["headline"]
          },
          %{
            "name" => "body",
            "type" => "String.t()",
            "required" => true,
            "aliases" => ["content", "text"]
          }
        ],
        "examples" => [
          "WRITE NEW BLOG POST FOR elchemista.com WITH: TITLE=\"My Post\" BODY=\"Hello world\""
        ]
      }
    ]
  end
end
