# Shows a briefing file in a topmost WPF window. ASCII-only on purpose (PS 5.1 encoding).
param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

Add-Type -AssemblyName PresentationFramework

$text = Get-Content $Path -Raw -Encoding UTF8

$window = New-Object System.Windows.Window
$window.Title = 'Daily Briefing - ' + (Get-Date -Format 'yyyy-MM-dd')
$window.Width = 900
$window.Height = 700
$window.WindowStartupLocation = 'CenterScreen'
$window.Topmost = $true
$window.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(30, 30, 34))

$scroll = New-Object System.Windows.Controls.ScrollViewer
$scroll.VerticalScrollBarVisibility = 'Auto'
$scroll.Padding = New-Object System.Windows.Thickness 24

$block = New-Object System.Windows.Controls.TextBox
$block.Text = $text
$block.IsReadOnly = $true
$block.TextWrapping = 'Wrap'
$block.BorderThickness = New-Object System.Windows.Thickness 0
$block.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI'
$block.FontSize = 16
$block.Background = [System.Windows.Media.Brushes]::Transparent
$block.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(230, 230, 235))

$scroll.Content = $block
$window.Content = $scroll

# Topmost only to grab attention on logon; release after activation so it doesn't block other work.
$window.Add_Activated({ $window.Topmost = $false })

$window.ShowDialog() | Out-Null
