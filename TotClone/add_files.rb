require 'xcodeproj'
project_path = '/Users/martystev/VS/personal/NoteObs/TotClone/TotClone.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.first

# Check to add to the main group 'TotClone'
group = project.main_group.children.find { |c| c.display_name == 'TotClone' || c.name == 'TotClone' }

files_to_add = [
    'Models.swift',
    'NotesViewModel.swift',
    'NotesFileStore.swift',
    'AppSettings.swift',
    'AppDelegate.swift',
    'LaunchAtLoginManager.swift',
    'Views.swift'
]

files_to_add.each do |filename|
    file_path = "/Users/martystev/VS/personal/NoteObs/TotClone/TotClone/#{filename}"
    existing = group.files.find { |f| f.path == filename || f.real_path.to_s == file_path }
    file_ref = existing || group.new_reference(file_path)

    unless target.source_build_phase.files_references.include?(file_ref)
        target.add_file_references([file_ref])
        puts "Added #{filename}"
    else
        puts "Skipped #{filename} (already in target)"
    end
end

project.save
