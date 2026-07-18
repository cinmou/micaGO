using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using MicaGo.App.Services;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Contracts;
using Windows.System;

namespace MicaGo.App.Views;

public sealed partial class ShellPage : Page
{
    private IMicaGoApi? _api;
    private readonly ObservableCollection<ChatSummary> _visibleChats = [];
    private readonly ObservableCollection<Message> _messages = [];
    private IReadOnlyList<ChatSummary> _allChats = [];
    private ChatSummary? _selectedChat;

    public ShellPage()
    {
        InitializeComponent();
        ChatList.ItemsSource = _visibleChats;
        MessageList.ItemsSource = _messages;
        Loaded += ShellPage_Loaded;
    }

    private async void ShellPage_Loaded(object sender, RoutedEventArgs e)
    {
        _api = AppServices.Current.Connection.Api;
        if (_api is null)
        {
            Frame.Navigate(typeof(ConnectionPage));
            return;
        }

        ConnectionStatusText.Text = $"Connected · {_api.BaseUrl}";
        try
        {
            _allChats = await _api.GetChatsAsync();
            ApplyChatFilter(string.Empty);
            if (_visibleChats.Count > 0)
            {
                ChatList.SelectedIndex = 0;
                await SelectChatAsync(_visibleChats[0]);
            }
            else
            {
                ConnectionStatusText.Text = "Connected · No conversations returned";
            }
        }
        catch (Exception exception)
        {
            ConnectionStatusText.Text = $"Connected · Could not load chats: {exception.Message}";
        }
    }

    private async void ChatList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ChatSummary chat)
        {
            await SelectChatAsync(chat);
        }
    }

    private async Task SelectChatAsync(ChatSummary chat)
    {
        _selectedChat = chat;
        ThreadTitle.Text = chat.Title;
        ThreadSubtitle.Text = chat.IsMuted
            ? $"{chat.ServiceLabel} · Notifications muted"
            : chat.ServiceLabel;
        _messages.Clear();
        if (_api is null)
        {
            return;
        }

        try
        {
            foreach (var message in await _api.GetMessagesAsync(chat.Id))
            {
                _messages.Add(message);
            }
        }
        catch (Exception exception)
        {
            ConnectionStatusText.Text = $"Could not load messages: {exception.Message}";
        }

        EmptyState.Visibility = Visibility.Collapsed;
        Composer.IsEnabled = chat.CanSendText;
        Composer.PlaceholderText = chat.CanSendText ? "Message" : $"Sending is unavailable for {chat.ServiceLabel}";
        SendButton.IsEnabled = !string.IsNullOrWhiteSpace(Composer.Text);
        ScrollToLastMessage();
    }

    private void SearchBox_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput)
        {
            ApplyChatFilter(sender.Text);
        }
    }

    private void ApplyChatFilter(string query)
    {
        _visibleChats.Clear();
        foreach (var chat in _allChats.Where(chat =>
                     string.IsNullOrWhiteSpace(query) ||
                     chat.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
                     chat.Preview.Contains(query, StringComparison.CurrentCultureIgnoreCase)))
        {
            _visibleChats.Add(chat);
        }
    }

    private void SettingsButton_Click(object sender, RoutedEventArgs e)
    {
        Frame.Navigate(typeof(SettingsPage));
    }

    private async void SendButton_Click(object sender, RoutedEventArgs e)
    {
        await SendCurrentTextAsync();
    }

    private async void Composer_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            await SendCurrentTextAsync();
        }
    }

    private void Composer_TextChanged(object sender, TextChangedEventArgs e)
    {
        SendButton.IsEnabled = _selectedChat is not null && !string.IsNullOrWhiteSpace(Composer.Text);
    }

    private async Task SendCurrentTextAsync()
    {
        var text = Composer.Text.Trim();
        if (_selectedChat is null || string.IsNullOrEmpty(text))
        {
            return;
        }

        Composer.Text = string.Empty;
        SendButton.IsEnabled = false;
        if (_api is null)
        {
            return;
        }

        try
        {
            _messages.Add(await _api.SendTextAsync(_selectedChat.Id, text));
            ScrollToLastMessage();
        }
        catch (Exception exception)
        {
            Composer.Text = text;
            ConnectionStatusText.Text = $"Send failed: {exception.Message}";
        }
    }

    private void ScrollToLastMessage()
    {
        if (_messages.Count > 0)
        {
            MessageList.ScrollIntoView(_messages[^1]);
        }
    }
}
